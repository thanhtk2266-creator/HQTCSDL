:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO

/* Existing notifications remain cruise-wide. New notifications may target
   one cruise, one role on that cruise, or one eligible user. */
IF COL_LENGTH(N'dbo.Notifications',N'TargetType') IS NULL
 ALTER TABLE dbo.Notifications ADD TargetType varchar(10) NOT NULL
  CONSTRAINT DF_Notifications_TargetType DEFAULT 'CRUISE' WITH VALUES;
IF COL_LENGTH(N'dbo.Notifications',N'TargetRoleId') IS NULL
 ALTER TABLE dbo.Notifications ADD TargetRoleId int NULL;
IF COL_LENGTH(N'dbo.Notifications',N'TargetUserId') IS NULL
 ALTER TABLE dbo.Notifications ADD TargetUserId int NULL;
GO
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name=N'FK_Notifications_TargetRole')
 ALTER TABLE dbo.Notifications ADD CONSTRAINT FK_Notifications_TargetRole
  FOREIGN KEY(TargetRoleId) REFERENCES dbo.Roles(RoleId);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name=N'FK_Notifications_TargetUser')
 ALTER TABLE dbo.Notifications ADD CONSTRAINT FK_Notifications_TargetUser
  FOREIGN KEY(TargetUserId) REFERENCES dbo.Users(UserId);
IF NOT EXISTS(SELECT 1 FROM sys.check_constraints WHERE name=N'CK_Notifications_Target')
 ALTER TABLE dbo.Notifications ADD CONSTRAINT CK_Notifications_Target CHECK(
  (TargetType='CRUISE' AND TargetRoleId IS NULL AND TargetUserId IS NULL) OR
  (TargetType='ROLE' AND TargetRoleId IS NOT NULL AND TargetUserId IS NULL) OR
  (TargetType='USER' AND TargetRoleId IS NULL AND TargetUserId IS NOT NULL));
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.Notifications') AND name=N'IX_Notifications_CruiseTarget')
 CREATE INDEX IX_Notifications_CruiseTarget ON dbo.Notifications(CruiseId,TargetType,TargetRoleId,TargetUserId,CreatedAt DESC);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Notify
 @CruiseId int,@Message nvarchar(500),@StaffId int,
 @TargetType varchar(10)='CRUISE',@TargetRoleId int=NULL,@TargetUserId int=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
  WHERE ur.UserId=@StaffId AND r.Code IN('ADMIN','ITINERARY','OPERATIONS'))
  THROW 51700,N'Không có quyền gửi thông báo.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Cruises WHERE CruiseId=@CruiseId)
  THROW 51701,N'Chuyến đi không tồn tại.',1;
 IF @Message IS NULL OR NULLIF(LTRIM(RTRIM(@Message)),N'') IS NULL OR LEN(@Message)>500
  THROW 51702,N'Nội dung thông báo phải có từ 1 đến 500 ký tự.',1;
 SET @TargetType=UPPER(LTRIM(RTRIM(COALESCE(@TargetType,''))));
 IF @TargetType NOT IN('CRUISE','ROLE','USER')
  THROW 51703,N'Đối tượng nhận thông báo không hợp lệ.',1;
 IF (@TargetType='CRUISE' AND (@TargetRoleId IS NOT NULL OR @TargetUserId IS NOT NULL)) OR
    (@TargetType='ROLE' AND (@TargetRoleId IS NULL OR @TargetUserId IS NOT NULL)) OR
    (@TargetType='USER' AND (@TargetUserId IS NULL OR @TargetRoleId IS NOT NULL))
  THROW 51704,N'Thông tin người nhận không khớp loại thông báo.',1;
 IF @TargetType='ROLE' AND NOT EXISTS(SELECT 1 FROM dbo.Roles WHERE RoleId=@TargetRoleId)
  THROW 51705,N'Vai trò nhận thông báo không tồn tại.',1;
 IF @TargetType='USER' AND NOT EXISTS(
  SELECT 1 FROM dbo.Users u WHERE u.UserId=@TargetUserId AND u.Active=1 AND (
   EXISTS(SELECT 1 FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
    WHERE b.CruiseId=@CruiseId AND p.UserId=u.UserId) OR
   EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
    WHERE ur.UserId=u.UserId AND r.Code<>'PASSENGER')))
  THROW 51706,N'Người dùng không hợp lệ hoặc không thuộc phạm vi chuyến.',1;
 DECLARE @NotificationId int,@CorrelationId uniqueidentifier=NEWID();
 BEGIN TRY
  BEGIN TRAN;
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@StaffId;
  EXEC sys.sp_set_session_context @key=N'CorrelationId',@value=@CorrelationId;
  INSERT dbo.Notifications(CruiseId,Message,TargetType,TargetRoleId,TargetUserId)
   VALUES(@CruiseId,LTRIM(RTRIM(@Message)),@TargetType,@TargetRoleId,@TargetUserId);
  SET @NotificationId=CONVERT(int,SCOPE_IDENTITY());
  INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId)
   VALUES('Notification',@NotificationId,'INSERT',@StaffId,
    CONCAT(N'Cruise=',@CruiseId,N'; Target=',@TargetType,N'; Role=',COALESCE(CONVERT(nvarchar(12),@TargetRoleId),N''),N'; User=',COALESCE(CONVERT(nvarchar(12),@TargetUserId),N'')),@CorrelationId);
  COMMIT;
  SELECT @NotificationId AS NotificationId;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReadNotification @NotificationId int,@UserId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Now datetime2(3)=SYSUTCDATETIME();
 IF NOT EXISTS(SELECT 1 FROM dbo.Notifications n JOIN dbo.Users u ON u.UserId=@UserId AND u.Active=1
  WHERE n.NotificationId=@NotificationId AND (
   (n.TargetType='CRUISE' AND (
    EXISTS(SELECT 1 FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
     WHERE b.CruiseId=n.CruiseId AND p.UserId=@UserId) OR
    EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
     WHERE ur.UserId=@UserId AND r.Code<>'PASSENGER')))
   OR (n.TargetType='ROLE' AND EXISTS(SELECT 1 FROM dbo.UserRoles ur
     WHERE ur.UserId=@UserId AND ur.RoleId=n.TargetRoleId) AND
     (NOT EXISTS(SELECT 1 FROM dbo.Roles r WHERE r.RoleId=n.TargetRoleId AND r.Code='PASSENGER') OR
      EXISTS(SELECT 1 FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
       WHERE b.CruiseId=n.CruiseId AND p.UserId=@UserId)))
   OR (n.TargetType='USER' AND n.TargetUserId=@UserId AND (
    EXISTS(SELECT 1 FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
     WHERE b.CruiseId=n.CruiseId AND p.UserId=@UserId) OR
    EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
     WHERE ur.UserId=@UserId AND r.Code<>'PASSENGER')))
  )) THROW 51707,N'Thông báo không thuộc phạm vi tài khoản.',1;
 BEGIN TRY
  BEGIN TRAN;
  IF NOT EXISTS(SELECT 1 FROM dbo.NotificationReads WITH(UPDLOCK,HOLDLOCK)
   WHERE NotificationId=@NotificationId AND UserId=@UserId)
   INSERT dbo.NotificationReads(NotificationId,UserId,ReadAt) VALUES(@NotificationId,@UserId,@Now);
  COMMIT;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
