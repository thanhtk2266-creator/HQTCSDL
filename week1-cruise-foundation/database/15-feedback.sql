:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO

IF COL_LENGTH('dbo.Feedback','CreatedAt') IS NULL
 ALTER TABLE dbo.Feedback ADD CreatedAt datetime2 NOT NULL CONSTRAINT DF_Feedback_CreatedAt DEFAULT SYSUTCDATETIME() WITH VALUES;
GO

IF OBJECT_ID('dbo.CruiseFeedback','U') IS NULL
BEGIN
 CREATE TABLE dbo.CruiseFeedback(
  FeedbackId int IDENTITY PRIMARY KEY,
  BookingId int NOT NULL UNIQUE REFERENCES dbo.Bookings(BookingId),
  CruiseId int NOT NULL REFERENCES dbo.Cruises(CruiseId),
  Rating int NOT NULL CHECK(Rating BETWEEN 1 AND 5),
  Comment nvarchar(500) NOT NULL CONSTRAINT DF_CruiseFeedback_Comment DEFAULT(N''),
  CreatedAt datetime2 NOT NULL CONSTRAINT DF_CruiseFeedback_CreatedAt DEFAULT SYSUTCDATETIME()
 );
END;
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.Feedback') AND name='IX_Feedback_Rating')
 CREATE INDEX IX_Feedback_Rating ON dbo.Feedback(RegistrationId) INCLUDE(Rating,CreatedAt);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.CruiseFeedback') AND name='IX_CruiseFeedback_Rating')
 CREATE INDEX IX_CruiseFeedback_Rating ON dbo.CruiseFeedback(CruiseId) INCLUDE(Rating,CreatedAt);
GO

CREATE OR ALTER PROCEDURE dbo.usp_SubmitFeedback
 @ActorId int,
 @Kind varchar(10),
 @Rating int,
 @Comment nvarchar(500)=NULL,
 @RegistrationId int=0,
 @BookingId int=0
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code='PASSENGER')
  THROW 51600,N'Chỉ hành khách mới được gửi đánh giá.',1;
 IF @Kind IS NULL OR @Kind NOT IN('ACTIVITY','CRUISE') THROW 51601,N'Loại đánh giá không hợp lệ.',1;
 IF @Rating IS NULL OR @Rating NOT BETWEEN 1 AND 5 THROW 51602,N'Điểm đánh giá phải từ 1 đến 5.',1;
 IF LEN(COALESCE(@Comment,N''))>500 THROW 51603,N'Nhận xét không được vượt quá 500 ký tự.',1;
 SET @Comment=NULLIF(LTRIM(RTRIM(@Comment)),N'');

 BEGIN TRY
  BEGIN TRAN;
  IF @Kind='ACTIVITY'
  BEGIN
   DECLARE @ActivityId int;
   SELECT @ActivityId=a.ActivityId
   FROM dbo.Registrations r WITH(UPDLOCK,HOLDLOCK)
   JOIN dbo.Activities a ON a.ActivityId=r.ActivityId
   JOIN dbo.Bookings b ON b.BookingId=r.BookingId
   JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
   WHERE r.RegistrationId=@RegistrationId AND p.UserId=@ActorId
     AND r.Status='CONFIRMED' AND a.Status='COMPLETED'
     AND EXISTS(SELECT 1 FROM dbo.CheckIns ci WHERE ci.RegistrationId=r.RegistrationId);
   IF @ActivityId IS NULL THROW 51604,N'Chỉ booking đã xác nhận, đã check-in và hoạt động đã hoàn thành mới được đánh giá.',1;
   IF EXISTS(SELECT 1 FROM dbo.Feedback WITH(UPDLOCK,HOLDLOCK) WHERE RegistrationId=@RegistrationId)
    THROW 51605,N'Bạn đã đánh giá hoạt động này rồi.',1;
   INSERT dbo.Feedback(RegistrationId,Rating,Comment) VALUES(@RegistrationId,@Rating,COALESCE(@Comment,N''));
   INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId)
    VALUES('Feedback',@RegistrationId,'INSERT',@ActorId,CONCAT(N'Kind=ACTIVITY; Rating=',@Rating),NEWID());
  END
  ELSE
  BEGIN
   DECLARE @CruiseId int;
   SELECT @CruiseId=b.CruiseId
   FROM dbo.Bookings b WITH(UPDLOCK,HOLDLOCK)
   JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
   JOIN dbo.Cruises c ON c.CruiseId=b.CruiseId
   WHERE b.BookingId=@BookingId AND p.UserId=@ActorId AND c.Status='CLOSED';
   IF @CruiseId IS NULL THROW 51606,N'Chỉ chủ booking của chuyến đã kết thúc mới được đánh giá chuyến đi.',1;
   IF EXISTS(SELECT 1 FROM dbo.CruiseFeedback WITH(UPDLOCK,HOLDLOCK) WHERE BookingId=@BookingId)
    THROW 51607,N'Booking này đã đánh giá chuyến đi rồi.',1;
   INSERT dbo.CruiseFeedback(BookingId,CruiseId,Rating,Comment) VALUES(@BookingId,@CruiseId,@Rating,COALESCE(@Comment,N''));
   INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId)
    VALUES('CruiseFeedback',@BookingId,'INSERT',@ActorId,CONCAT(N'CruiseId=',@CruiseId,N'; Rating=',@Rating),NEWID());
  END
  COMMIT;
  SELECT CAST(1 AS bit) AS Saved;
 END TRY
 BEGIN CATCH
  IF @@TRANCOUNT>0 ROLLBACK;
  THROW;
 END CATCH
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_CruiseFeedbackConsistency ON dbo.CruiseFeedback AFTER INSERT,UPDATE AS
BEGIN
 SET NOCOUNT ON;
 IF EXISTS(SELECT 1 FROM inserted f JOIN dbo.Bookings b ON b.BookingId=f.BookingId WHERE b.CruiseId<>f.CruiseId)
  THROW 51610,N'Đánh giá chuyến đi phải khớp chuyến của booking.',1;
END;
GO
