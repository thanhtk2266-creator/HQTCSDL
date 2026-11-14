:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO

-- A booking can have many historical attempts, but only one live registration per activity.
DECLARE @RegistrationUniqueConstraint sysname;
DECLARE @DropConstraintSql nvarchar(512);
SELECT TOP(1) @RegistrationUniqueConstraint=kc.name
FROM sys.key_constraints kc
JOIN sys.index_columns ic1 ON ic1.object_id=kc.parent_object_id AND ic1.index_id=kc.unique_index_id
JOIN sys.columns c1 ON c1.object_id=ic1.object_id AND c1.column_id=ic1.column_id
WHERE kc.parent_object_id=OBJECT_ID('dbo.Registrations') AND kc.type='UQ' AND c1.name='ActivityId'
 AND EXISTS(
  SELECT 1 FROM sys.index_columns ic2 JOIN sys.columns c2 ON c2.object_id=ic2.object_id AND c2.column_id=ic2.column_id
  WHERE ic2.object_id=kc.parent_object_id AND ic2.index_id=kc.unique_index_id AND c2.name='BookingId'
 );
IF @RegistrationUniqueConstraint IS NOT NULL
BEGIN
 SET @DropConstraintSql=N'ALTER TABLE dbo.Registrations DROP CONSTRAINT '+QUOTENAME(@RegistrationUniqueConstraint);
 EXEC sys.sp_executesql @DropConstraintSql;
END;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.Registrations') AND name='UX_Registrations_ActiveBookingActivity')
 CREATE UNIQUE INDEX UX_Registrations_ActiveBookingActivity ON dbo.Registrations(ActivityId,BookingId) WHERE Status<>'CANCELLED';
GO

IF OBJECT_ID('dbo.RegistrationHistory','U') IS NULL
BEGIN
 CREATE TABLE dbo.RegistrationHistory(
  RegistrationHistoryId bigint IDENTITY PRIMARY KEY,
  RegistrationId int NOT NULL REFERENCES dbo.Registrations(RegistrationId),
  EventType varchar(20) NOT NULL CHECK(EventType IN('REGISTERED','RE_REGISTERED','CANCELLED','STATUS_CHANGED')),
  FromStatus varchar(20) NULL,
  ToStatus varchar(20) NOT NULL CHECK(ToStatus IN('CONFIRMED','WAITLIST','CANCELLED')),
  OccurredAt datetime2 NOT NULL,
  ActorId int NULL REFERENCES dbo.Users(UserId),
  Details nvarchar(500) NULL
 );
 CREATE INDEX IX_RegistrationHistory_RegistrationTime ON dbo.RegistrationHistory(RegistrationId,OccurredAt,RegistrationHistoryId);
END;
GO

-- Seed history for registration attempts created before this migration.
INSERT dbo.RegistrationHistory(RegistrationId,EventType,FromStatus,ToStatus,OccurredAt,ActorId,Details)
SELECT r.RegistrationId,'REGISTERED',NULL,r.Status,r.CreatedAt,NULL,N'Đăng ký trước khi bật theo dõi lịch sử.'
FROM dbo.Registrations r
WHERE NOT EXISTS(SELECT 1 FROM dbo.RegistrationHistory h WHERE h.RegistrationId=r.RegistrationId AND h.EventType IN('REGISTERED','RE_REGISTERED'));
INSERT dbo.RegistrationHistory(RegistrationId,EventType,FromStatus,ToStatus,OccurredAt,ActorId,Details)
SELECT r.RegistrationId,'CANCELLED',r.Status,'CANCELLED',COALESCE(r.CancelledAt,r.CreatedAt),r.CancelledBy,r.CancelReason
FROM dbo.Registrations r
WHERE r.Status='CANCELLED' AND NOT EXISTS(SELECT 1 FROM dbo.RegistrationHistory h WHERE h.RegistrationId=r.RegistrationId AND h.EventType='CANCELLED');
GO

CREATE OR ALTER TRIGGER dbo.tr_RegistrationStampCancellation ON dbo.Registrations AFTER UPDATE AS
BEGIN
 SET NOCOUNT ON;
 UPDATE r SET CancelledAt=COALESCE(i.CancelledAt,SYSUTCDATETIME()),
  CancelledBy=COALESCE(i.CancelledBy,TRY_CONVERT(int,SESSION_CONTEXT(N'ActorId')))
 FROM dbo.Registrations r JOIN inserted i ON i.RegistrationId=r.RegistrationId
 JOIN deleted d ON d.RegistrationId=i.RegistrationId
 WHERE i.Status='CANCELLED' AND d.Status<>'CANCELLED' AND i.CancelledAt IS NULL;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_RegistrationHistory ON dbo.Registrations AFTER INSERT,UPDATE AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @ActorId int=TRY_CONVERT(int,SESSION_CONTEXT(N'ActorId'));
 INSERT dbo.RegistrationHistory(RegistrationId,EventType,FromStatus,ToStatus,OccurredAt,ActorId,Details)
 SELECT i.RegistrationId,
  CASE WHEN d.RegistrationId IS NULL THEN
   CASE WHEN EXISTS(SELECT 1 FROM dbo.Registrations old WHERE old.ActivityId=i.ActivityId AND old.BookingId=i.BookingId AND old.RegistrationId<>i.RegistrationId AND old.Status='CANCELLED') THEN 'RE_REGISTERED' ELSE 'REGISTERED' END
   WHEN d.Status='CANCELLED' THEN 'STATUS_CHANGED'
   WHEN i.Status='CANCELLED' THEN 'CANCELLED'
   ELSE 'STATUS_CHANGED' END,
  d.Status,i.Status,
  CASE WHEN i.Status='CANCELLED' THEN COALESCE(i.CancelledAt,SYSUTCDATETIME())
   WHEN d.RegistrationId IS NULL THEN COALESCE(i.CreatedAt,SYSUTCDATETIME()) ELSE SYSUTCDATETIME() END,
  COALESCE(i.CancelledBy,@ActorId),
  CASE WHEN i.Status='CANCELLED' THEN i.CancelReason
   WHEN d.RegistrationId IS NULL AND i.Status='WAITLIST' THEN N'Đăng ký mới, đưa vào danh sách chờ.'
   WHEN d.RegistrationId IS NOT NULL THEN CONCAT(N'Trạng thái: ',d.Status,N' → ',i.Status)
   ELSE N'Đăng ký mới.' END
 FROM inserted i LEFT JOIN deleted d ON d.RegistrationId=i.RegistrationId
 WHERE d.RegistrationId IS NULL OR d.Status<>i.Status;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_RegistrationPreventDelete ON dbo.Registrations INSTEAD OF DELETE AS
BEGIN
 SET NOCOUNT ON;
 IF EXISTS(SELECT 1 FROM deleted)
  THROW 51720,N'Không được xóa đăng ký; hãy chuyển trạng thái để lưu dấu vết nghiệp vụ.',1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Register
 @BookingId int,@ActivityId int,@ActorId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 BEGIN TRY
  BEGIN TRAN;
  DECLARE @CruiseId int,@Capacity int,@Fee decimal(18,2),@StartsAt datetime2,@ActivityStatus varchar(20),
   @IncludedServiceId int,@AccountId int,@PackageId int,@BookingCruiseId int,@Price decimal(18,2),
   @RegistrationStatus varchar(20),@OpenHours int,@CloseHours int,@Now datetime2=SYSDATETIME();
  SELECT @CruiseId=a.CruiseId,@Capacity=a.Capacity,@Fee=a.Fee,@StartsAt=a.StartsAt,@ActivityStatus=a.Status,
   @IncludedServiceId=a.IncludedServiceId,@OpenHours=COALESCE(a.RegistrationOpenHours,p.RegistrationOpenHours),
   @CloseHours=COALESCE(a.RegistrationCloseHours,p.RegistrationCloseHours)
  FROM dbo.Activities a WITH(UPDLOCK,HOLDLOCK) CROSS JOIN dbo.Policy p
  WHERE a.ActivityId=@ActivityId AND p.PolicyId=1;
  IF @CruiseId IS NULL THROW 51262,N'Hoạt động không tồn tại.',1;
  IF @ActivityStatus<>'OPEN' OR @Now<DATEADD(HOUR,-@OpenHours,@StartsAt) OR @Now>=DATEADD(HOUR,-@CloseHours,@StartsAt)
   THROW 51263,N'Hoạt động chưa mở đăng ký hoặc đã quá thời hạn đăng ký.',1;
  SELECT @BookingCruiseId=b.CruiseId,@PackageId=b.PackageId FROM dbo.Bookings b JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId AND c.Status<>'CLOSED' WHERE b.BookingId=@BookingId;
  IF @BookingCruiseId IS NULL OR @BookingCruiseId<>@CruiseId THROW 51264,N'Booking không thuộc chuyến đang mở của hoạt động.',1;
  IF NOT EXISTS(SELECT 1 FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId WHERE b.BookingId=@BookingId AND p.UserId=@ActorId)
   AND NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code='ADMIN') THROW 51265,N'Không có quyền đăng ký cho booking này.',1;
  IF EXISTS(SELECT 1 FROM dbo.Registrations WHERE BookingId=@BookingId AND ActivityId=@ActivityId AND Status<>'CANCELLED') THROW 51266,N'Booking đã có đăng ký còn hiệu lực cho hoạt động này.',1;
  SELECT @AccountId=AccountId FROM dbo.Accounts WITH(UPDLOCK,HOLDLOCK) WHERE BookingId=@BookingId AND Status='OPEN';
  IF @AccountId IS NULL THROW 51267,N'Tài khoản booking đã chốt hoặc chưa tồn tại.',1;
  SET @Price=@Fee;
  IF @IncludedServiceId IS NOT NULL AND EXISTS(SELECT 1 FROM dbo.PackageServices WHERE PackageId=@PackageId AND ServiceId=@IncludedServiceId) SET @Price=0;
  SET @RegistrationStatus=CASE WHEN (SELECT COUNT(*) FROM dbo.Registrations WHERE ActivityId=@ActivityId AND Status='CONFIRMED')>=@Capacity THEN 'WAITLIST' ELSE 'CONFIRMED' END;
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@ActorId;
  INSERT dbo.Registrations(ActivityId,BookingId,Status,PriceAtRegistration) VALUES(@ActivityId,@BookingId,@RegistrationStatus,@Price);
  DECLARE @RegistrationId int=SCOPE_IDENTITY();
  IF @RegistrationStatus='CONFIRMED' INSERT dbo.Transactions(AccountId,RegistrationId,Amount) VALUES(@AccountId,@RegistrationId,@Price);
  COMMIT; SELECT @RegistrationId AS RegistrationId,@RegistrationStatus AS Status,@Price AS PriceAtRegistration;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
