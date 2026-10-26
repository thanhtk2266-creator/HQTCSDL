:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO

IF COL_LENGTH(N'dbo.Transactions',N'ReconciledAt') IS NULL
 ALTER TABLE dbo.Transactions ADD ReconciledAt datetime2(3) NULL;
IF COL_LENGTH(N'dbo.Transactions',N'ReconciledBy') IS NULL
 ALTER TABLE dbo.Transactions ADD ReconciledBy int NULL;
GO

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name=N'FK_Transactions_ReconciledBy')
 ALTER TABLE dbo.Transactions ADD CONSTRAINT FK_Transactions_ReconciledBy FOREIGN KEY(ReconciledBy) REFERENCES dbo.Users(UserId);
GO

IF OBJECT_ID(N'dbo.NotificationReads',N'U') IS NULL
 CREATE TABLE dbo.NotificationReads(
  NotificationId int NOT NULL REFERENCES dbo.Notifications(NotificationId),
  UserId int NOT NULL REFERENCES dbo.Users(UserId),
  ReadAt datetime2(3) NOT NULL CONSTRAINT DF_NotificationReads_ReadAt DEFAULT SYSUTCDATETIME(),
  CONSTRAINT PK_NotificationReads PRIMARY KEY(NotificationId,UserId)
 );
GO

CREATE OR ALTER FUNCTION dbo.fn_AccountBalance(@AccountId int)
RETURNS decimal(18,2)
AS
BEGIN
 RETURN (SELECT CONVERT(decimal(18,2),COALESCE(SUM(CASE Status
  WHEN 'POSTED' THEN Amount
  WHEN 'REFUNDED' THEN Amount-COALESCE(RefundAmount,0)
  ELSE 0 END),0)) FROM dbo.Transactions WHERE AccountId=@AccountId);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_FinanceTransaction
 @TransactionId int,@StaffId int,@Status varchar(20)
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 EXEC dbo.usp_RequireRole @StaffId,'FINANCE';
 IF @Status IS NULL OR @Status NOT IN('REFUNDED','VOID') THROW 51600,N'Trạng thái xử lý giao dịch không hợp lệ.',1;
 BEGIN TRY
  BEGIN TRAN;
  DECLARE @AccountId int,@ServiceId int,@RegistrationId int,@CurrentStatus varchar(20),@CorrelationId uniqueidentifier=NEWID();
  SELECT @AccountId=AccountId FROM dbo.Transactions WHERE TransactionId=@TransactionId;
  IF @AccountId IS NULL THROW 51601,N'Giao dịch không tồn tại.',1;
  IF NOT EXISTS(SELECT 1 FROM dbo.Accounts WITH(UPDLOCK,HOLDLOCK) WHERE AccountId=@AccountId AND Status='OPEN')
   THROW 51602,N'Tài khoản đã chốt.',1;
  SELECT @ServiceId=ServiceId,@RegistrationId=RegistrationId,@CurrentStatus=Status
   FROM dbo.Transactions WITH(UPDLOCK,HOLDLOCK) WHERE TransactionId=@TransactionId AND AccountId=@AccountId;
  IF @ServiceId IS NULL OR @RegistrationId IS NOT NULL
   THROW 51603,N'Phí đăng ký phải xử lý qua nghiệp vụ hủy đăng ký.',1;
  IF @CurrentStatus<>'POSTED' THROW 51604,N'Giao dịch không còn hiệu lực để xử lý.',1;
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@StaffId;
  EXEC sys.sp_set_session_context @key=N'CorrelationId',@value=@CorrelationId;
  UPDATE dbo.Transactions SET Status=@Status,
   RefundAmount=CASE WHEN @Status='REFUNDED' THEN Amount ELSE 0 END,
   RefundedAt=CASE WHEN @Status='REFUNDED' THEN SYSUTCDATETIME() ELSE NULL END
   WHERE TransactionId=@TransactionId AND Status='POSTED';
  IF @@ROWCOUNT=0 THROW 51604,N'Giao dịch không còn hiệu lực để xử lý.',1;
  UPDATE dbo.Disputes SET Status='RESOLVED',ResolvedAt=SYSUTCDATETIME(),ResolvedBy=@StaffId,
   Resolution=CONCAT(N'Đã ',CASE WHEN @Status='REFUNDED' THEN N'hoàn tiền' ELSE N'void' END,N' giao dịch.')
   WHERE TransactionId=@TransactionId AND Status='OPEN';
  COMMIT;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Reconcile @TransactionId int,@StaffId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 EXEC dbo.usp_RequireRole @StaffId,'FINANCE';
 BEGIN TRY
  BEGIN TRAN;
  DECLARE @AccountId int,@ServiceId int,@Status varchar(20),@CorrelationId uniqueidentifier=NEWID();
  SELECT @AccountId=AccountId FROM dbo.Transactions WHERE TransactionId=@TransactionId;
  IF @AccountId IS NULL THROW 51605,N'Giao dịch POS không tồn tại.',1;
  IF NOT EXISTS(SELECT 1 FROM dbo.Accounts WITH(UPDLOCK,HOLDLOCK) WHERE AccountId=@AccountId AND Status='OPEN')
   THROW 51606,N'Tài khoản đã chốt.',1;
  SELECT @ServiceId=ServiceId,@Status=Status FROM dbo.Transactions WITH(UPDLOCK,HOLDLOCK)
   WHERE TransactionId=@TransactionId AND AccountId=@AccountId;
  IF @ServiceId IS NULL OR @Status<>'POSTED' THROW 51605,N'Chỉ đối soát giao dịch POS đang ghi nhận.',1;
  IF EXISTS(SELECT 1 FROM dbo.Disputes WHERE TransactionId=@TransactionId AND Status='OPEN')
   THROW 51607,N'Xử lý tranh chấp trước khi đối soát.',1;
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@StaffId;
  EXEC sys.sp_set_session_context @key=N'CorrelationId',@value=@CorrelationId;
  UPDATE dbo.Transactions SET ReconciledAt=SYSUTCDATETIME(),ReconciledBy=@StaffId
   WHERE TransactionId=@TransactionId AND Status='POSTED' AND ReconciledAt IS NULL;
  IF @@ROWCOUNT=0 THROW 51608,N'Giao dịch đã được đối soát.',1;
  COMMIT;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SettleAccount
 @AccountId int,@ActorId int,@Method varchar(20)
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
  WHERE ur.UserId=@ActorId AND r.Code IN('FINANCE','ADMIN'))
  THROW 51609,N'Chỉ tài chính hoặc quản trị viên được chốt tài khoản.',1;
 IF @Method IS NULL OR UPPER(LTRIM(RTRIM(@Method))) NOT IN('CASH','CARD','TRANSFER','MOCK')
  THROW 51610,N'Phương thức thanh toán không hợp lệ.',1;
 BEGIN TRY
  BEGIN TRAN;
  IF NOT EXISTS(SELECT 1 FROM dbo.Accounts WITH(UPDLOCK,HOLDLOCK) WHERE AccountId=@AccountId AND Status='OPEN')
   THROW 51611,N'Tài khoản đã chốt hoặc không tồn tại.',1;
  IF EXISTS(SELECT 1 FROM dbo.Disputes d JOIN dbo.Transactions t ON t.TransactionId=d.TransactionId
   WHERE t.AccountId=@AccountId AND d.Status='OPEN')
   THROW 51612,N'Phải xử lý hết tranh chấp trước khi chốt tài khoản.',1;
  IF EXISTS(SELECT 1 FROM dbo.Transactions WHERE AccountId=@AccountId AND ServiceId IS NOT NULL
   AND Status='POSTED' AND ReconciledAt IS NULL)
   THROW 51613,N'Còn giao dịch POS chưa đối soát.',1;
  IF EXISTS(SELECT 1 FROM dbo.Invoices WHERE AccountId=@AccountId)
   THROW 51614,N'Tài khoản đã có hóa đơn.',1;
  DECLARE @Total decimal(18,2)=dbo.fn_AccountBalance(@AccountId),@InvoiceId int,
   @CorrelationId uniqueidentifier=NEWID();
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@ActorId;
  EXEC sys.sp_set_session_context @key=N'CorrelationId',@value=@CorrelationId;
  INSERT dbo.Invoices(AccountId,Total) VALUES(@AccountId,@Total);
  SET @InvoiceId=CONVERT(int,SCOPE_IDENTITY());
  INSERT dbo.Payments(InvoiceId,Amount,Method) VALUES(@InvoiceId,@Total,UPPER(LTRIM(RTRIM(@Method))));
  UPDATE dbo.Accounts SET Status='SETTLED' WHERE AccountId=@AccountId;
  UPDATE dbo.Registrations SET Status='CANCELLED'
   WHERE BookingId=(SELECT BookingId FROM dbo.Accounts WHERE AccountId=@AccountId) AND Status='WAITLIST';
  COMMIT;
  SELECT @AccountId AS AccountId,@InvoiceId AS InvoiceId,@Total AS Total,'SETTLED' AS Status,@CorrelationId AS CorrelationId;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ResolveDispute
 @DisputeId int,@StaffId int,@Resolution nvarchar(500)
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 EXEC dbo.usp_RequireRole @StaffId,'FINANCE';
 BEGIN TRY
  BEGIN TRAN;
  DECLARE @CorrelationId uniqueidentifier=NEWID();
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@StaffId;
  EXEC sys.sp_set_session_context @key=N'CorrelationId',@value=@CorrelationId;
  UPDATE dbo.Disputes WITH(UPDLOCK,HOLDLOCK)
   SET Status='RESOLVED',ResolvedAt=SYSUTCDATETIME(),ResolvedBy=@StaffId,
    Resolution=COALESCE(NULLIF(LTRIM(RTRIM(@Resolution)),N''),N'Đã kiểm tra và xử lý.')
   WHERE DisputeId=@DisputeId AND Status='OPEN';
  IF @@ROWCOUNT=0 THROW 51615,N'Tranh chấp không tồn tại hoặc đã xử lý.',1;
  COMMIT;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Notify @CruiseId int,@Message nvarchar(500),@StaffId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
  WHERE ur.UserId=@StaffId AND r.Code IN('ADMIN','ITINERARY','OPERATIONS'))
  THROW 51616,N'Không có quyền gửi thông báo.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Cruises WHERE CruiseId=@CruiseId) THROW 51617,N'Chuyến đi không tồn tại.',1;
 IF @Message IS NULL OR NULLIF(LTRIM(RTRIM(@Message)),N'') IS NULL OR LEN(@Message)>500
  THROW 51618,N'Nội dung thông báo phải có từ 1 đến 500 ký tự.',1;
 DECLARE @NotificationId int,@CorrelationId uniqueidentifier=NEWID();
 BEGIN TRY
  BEGIN TRAN;
  EXEC sys.sp_set_session_context @key=N'ActorId',@value=@StaffId;
  EXEC sys.sp_set_session_context @key=N'CorrelationId',@value=@CorrelationId;
  INSERT dbo.Notifications(CruiseId,Message) VALUES(@CruiseId,LTRIM(RTRIM(@Message)));
  SET @NotificationId=CONVERT(int,SCOPE_IDENTITY());
  INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId)
   VALUES('Notification',@NotificationId,'INSERT',@StaffId,CONCAT(N'Cruise=',@CruiseId),@CorrelationId);
  COMMIT;
  SELECT @NotificationId AS NotificationId;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReadNotification @NotificationId int,@UserId int
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.Notifications n WHERE n.NotificationId=@NotificationId AND (
  EXISTS(SELECT 1 FROM dbo.Bookings b JOIN dbo.Passengers p ON p.PassengerId=b.PassengerId
   WHERE b.CruiseId=n.CruiseId AND p.UserId=@UserId)
  OR EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId
   WHERE ur.UserId=@UserId AND r.Code<>'PASSENGER')
 )) THROW 51619,N'Thông báo không thuộc phạm vi tài khoản.',1;
 BEGIN TRY
  BEGIN TRAN;
  IF NOT EXISTS(SELECT 1 FROM dbo.NotificationReads WITH(UPDLOCK,HOLDLOCK)
   WHERE NotificationId=@NotificationId AND UserId=@UserId)
   INSERT dbo.NotificationReads(NotificationId,UserId) VALUES(@NotificationId,@UserId);
  COMMIT;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
