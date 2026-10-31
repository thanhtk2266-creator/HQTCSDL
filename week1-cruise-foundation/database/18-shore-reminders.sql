:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO

/* A dispatch row is both the audit trail and the idempotency key for one
   reminder, one registration, and one version of the activity schedule. */
IF OBJECT_ID(N'dbo.ShoreReminderDispatches',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.ShoreReminderDispatches(
  DispatchId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ShoreReminderDispatches PRIMARY KEY,
  RegistrationId int NOT NULL CONSTRAINT FK_ShoreReminderDispatches_Registration REFERENCES dbo.Registrations(RegistrationId),
  ActivityId int NOT NULL CONSTRAINT FK_ShoreReminderDispatches_Activity REFERENCES dbo.Activities(ActivityId),
  UserId int NOT NULL CONSTRAINT FK_ShoreReminderDispatches_User REFERENCES dbo.Users(UserId),
  ReminderType varchar(20) NOT NULL CONSTRAINT CK_ShoreReminderDispatches_Type CHECK(ReminderType IN('GATHERING','RETURN_TO_SHIP')),
  ScheduledFor datetime2(7) NOT NULL,
  NotificationId int NOT NULL CONSTRAINT FK_ShoreReminderDispatches_Notification REFERENCES dbo.Notifications(NotificationId),
  CreatedAt datetime2(3) NOT NULL CONSTRAINT DF_ShoreReminderDispatches_CreatedAt DEFAULT SYSUTCDATETIME(),
  CONSTRAINT UQ_ShoreReminderDispatches_Event UNIQUE(RegistrationId,ReminderType,ScheduledFor)
 );
 CREATE INDEX IX_ShoreReminderDispatches_Notification ON dbo.ShoreReminderDispatches(NotificationId);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GenerateShoreReminders
 @NowUtc datetime2(7)=NULL,
 @GatherMinutes int=30,
 @ReturnMinutes int=15
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 SET @NowUtc=COALESCE(@NowUtc,SYSUTCDATETIME());
 IF @GatherMinutes NOT BETWEEN 1 AND 1440 OR @ReturnMinutes NOT BETWEEN 1 AND 1440
  THROW 51800,N'Thời gian nhắc phải nằm trong khoảng 1 đến 1440 phút.',1;

 CREATE TABLE #Due(
  RegistrationId int NOT NULL,
  ActivityId int NOT NULL,
  CruiseId int NOT NULL,
  UserId int NOT NULL,
  ReminderType varchar(20) NOT NULL,
  ScheduledFor datetime2(7) NOT NULL,
  ActivityName nvarchar(150) NOT NULL,
  PRIMARY KEY(RegistrationId,ReminderType,ScheduledFor)
 );

 /* Gathering: confirmed shore guests who have not checked in yet. */
 INSERT #Due(RegistrationId,ActivityId,CruiseId,UserId,ReminderType,ScheduledFor,ActivityName)
 SELECT r.RegistrationId,a.ActivityId,a.CruiseId,u.UserId,'GATHERING',a.StartsAt,a.Name
 FROM dbo.Registrations r
 JOIN dbo.Activities a ON a.ActivityId=r.ActivityId
 JOIN dbo.Bookings b ON b.BookingId=r.BookingId
 JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
 JOIN dbo.Users u ON u.UserId=p.UserId AND u.Active=1
 WHERE a.Kind='SHORE' AND a.Status IN('OPEN','DELAYED')
  AND r.Status='CONFIRMED'
  AND a.StartsAt>@NowUtc
  AND @NowUtc>=DATEADD(minute,-@GatherMinutes,a.StartsAt)
  AND NOT EXISTS(SELECT 1 FROM dbo.CheckIns ci WHERE ci.RegistrationId=r.RegistrationId);

 /* Return to ship: checked-in guests without ReturnedAt. Keep this reminder
    active even if a tour was cancelled after the guest had checked in. */
 INSERT #Due(RegistrationId,ActivityId,CruiseId,UserId,ReminderType,ScheduledFor,ActivityName)
 SELECT r.RegistrationId,a.ActivityId,a.CruiseId,u.UserId,'RETURN_TO_SHIP',a.ReturnAt,a.Name
 FROM dbo.Registrations r
 JOIN dbo.Activities a ON a.ActivityId=r.ActivityId
 JOIN dbo.Bookings b ON b.BookingId=r.BookingId
 JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
 JOIN dbo.Users u ON u.UserId=p.UserId AND u.Active=1
 JOIN dbo.CheckIns ci ON ci.RegistrationId=r.RegistrationId AND ci.ReturnedAt IS NULL
 WHERE a.Kind='SHORE' AND a.ReturnAt IS NOT NULL
  AND @NowUtc>=DATEADD(minute,-@ReturnMinutes,a.ReturnAt);

 DECLARE @Created int=0,@LockResult int;
 BEGIN TRY
  BEGIN TRAN;
  EXEC @LockResult=sys.sp_getapplock
   @Resource=N'AuroraCruise:GenerateShoreReminders',
   @LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
  IF @LockResult<0
  BEGIN
   ROLLBACK;
   SELECT @Created AS RemindersCreated;
   RETURN;
  END;

  DECLARE @RegistrationId int,@ActivityId int,@CruiseId int,@UserId int,
   @ReminderType varchar(20),@ScheduledFor datetime2(7),@ActivityName nvarchar(150),
   @NotificationId int,@Message nvarchar(500);
  DECLARE reminder_cursor CURSOR LOCAL FAST_FORWARD FOR
   SELECT d.RegistrationId,d.ActivityId,d.CruiseId,d.UserId,d.ReminderType,d.ScheduledFor,d.ActivityName
   FROM #Due d
   WHERE NOT EXISTS(
    SELECT 1 FROM dbo.ShoreReminderDispatches x WITH(UPDLOCK,HOLDLOCK)
    WHERE x.RegistrationId=d.RegistrationId
     AND x.ReminderType=d.ReminderType
     AND x.ScheduledFor=d.ScheduledFor)
   ORDER BY d.ScheduledFor,d.RegistrationId,d.ReminderType;
  OPEN reminder_cursor;
  FETCH NEXT FROM reminder_cursor INTO @RegistrationId,@ActivityId,@CruiseId,@UserId,@ReminderType,@ScheduledFor,@ActivityName;
  WHILE @@FETCH_STATUS=0
  BEGIN
   SET @Message=CASE @ReminderType
    WHEN 'GATHERING' THEN LEFT(CONCAT(N'Nhắc tập trung: tour “',@ActivityName,N'” bắt đầu lúc ',CONVERT(nvarchar(16),@ScheduledFor,120),N'. Vui lòng đến điểm tập trung đúng giờ.'),500)
    ELSE LEFT(CONCAT(N'Nhắc về tàu: tour “',@ActivityName,N'” dự kiến về tàu lúc ',CONVERT(nvarchar(16),@ScheduledFor,120),N'. Hệ thống chưa ghi nhận bạn trở về; vui lòng báo nhân viên ngay khi đã lên tàu.'),500)
   END;
   INSERT dbo.Notifications(CruiseId,Message,TargetType,TargetUserId)
    VALUES(@CruiseId,@Message,'USER',@UserId);
   SET @NotificationId=CONVERT(int,SCOPE_IDENTITY());
   INSERT dbo.ShoreReminderDispatches(RegistrationId,ActivityId,UserId,ReminderType,ScheduledFor,NotificationId)
    VALUES(@RegistrationId,@ActivityId,@UserId,@ReminderType,@ScheduledFor,@NotificationId);
   SET @Created+=1;
   FETCH NEXT FROM reminder_cursor INTO @RegistrationId,@ActivityId,@CruiseId,@UserId,@ReminderType,@ScheduledFor,@ActivityName;
  END;
  CLOSE reminder_cursor;
  DEALLOCATE reminder_cursor;
  COMMIT;
  SELECT @Created AS RemindersCreated;
 END TRY
 BEGIN CATCH
  IF CURSOR_STATUS('local','reminder_cursor')>=0 CLOSE reminder_cursor;
  IF CURSOR_STATUS('local','reminder_cursor')>-3 DEALLOCATE reminder_cursor;
  IF @@TRANCOUNT>0 ROLLBACK;
  THROW;
 END CATCH
END;
GO
