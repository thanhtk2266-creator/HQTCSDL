:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO

-- Ledger rows are append-only. Corrections must use the refund/void workflows.
CREATE OR ALTER TRIGGER dbo.tr_ProtectSettledTransactions ON dbo.Transactions AFTER DELETE AS
BEGIN
 SET NOCOUNT ON;
 IF EXISTS(SELECT 1 FROM deleted)
  THROW 51730,N'Không được xóa giao dịch khỏi sổ tài chính; hãy dùng nghiệp vụ hoàn hoặc void.',1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_TransactionLedgerGuard ON dbo.Transactions AFTER INSERT,UPDATE AS
BEGIN
 SET NOCOUNT ON;
 IF EXISTS(
  SELECT 1 FROM inserted t LEFT JOIN deleted old ON old.TransactionId=t.TransactionId
  WHERE old.TransactionId IS NULL AND (t.Status<>'POSTED' OR t.RefundAmount IS NOT NULL OR t.RefundedAt IS NOT NULL
      OR t.RefundedBy IS NOT NULL OR t.ReconciledAt IS NOT NULL OR t.ReconciledBy IS NOT NULL)
 ) THROW 51736,N'Giao dịch mới phải bắt đầu ở trạng thái POSTED, chưa hoàn hoặc đối soát.',1;

 IF EXISTS(
  SELECT 1 FROM inserted t LEFT JOIN deleted old ON old.TransactionId=t.TransactionId
  JOIN dbo.Accounts ac ON ac.AccountId=t.AccountId
  LEFT JOIN dbo.Registrations r ON r.RegistrationId=t.RegistrationId
  LEFT JOIN dbo.Activities a ON a.ActivityId=r.ActivityId
  LEFT JOIN dbo.Services s ON s.ServiceId=t.ServiceId
  LEFT JOIN dbo.Bookings b ON b.BookingId=ac.BookingId
  WHERE old.TransactionId IS NULL AND (
   (t.RegistrationId IS NOT NULL AND r.Status<>'CONFIRMED')
   OR (t.RegistrationId IS NOT NULL AND r.PriceAtRegistration IS NOT NULL AND t.Amount<>r.PriceAtRegistration)
   OR (t.ServiceId IS NOT NULL AND t.Amount<>t.Quantity*CASE WHEN EXISTS(
      SELECT 1 FROM dbo.PackageServices ps WHERE ps.PackageId=b.PackageId AND ps.ServiceId=t.ServiceId
     ) THEN 0 ELSE s.Price END)
  )
 ) THROW 51737,N'Số tiền giao dịch mới không khớp giá dịch vụ/gói hoặc đăng ký đã xác nhận.',1;

 IF EXISTS(
  SELECT 1 FROM inserted i JOIN deleted d ON d.TransactionId=i.TransactionId
  WHERE i.AccountId<>d.AccountId OR ISNULL(i.RegistrationId,-1)<>ISNULL(d.RegistrationId,-1)
   OR ISNULL(i.ServiceId,-1)<>ISNULL(d.ServiceId,-1) OR ISNULL(i.DeviceId,-1)<>ISNULL(d.DeviceId,-1)
   OR ISNULL(i.StaffId,-1)<>ISNULL(d.StaffId,-1) OR i.ClientId<>d.ClientId
   OR i.Quantity<>d.Quantity OR i.Amount<>d.Amount OR i.CreatedAt<>d.CreatedAt
 ) THROW 51731,N'Không được sửa nội dung gốc của giao dịch tài chính.',1;

 IF EXISTS(
  SELECT 1 FROM inserted i JOIN deleted d ON d.TransactionId=i.TransactionId
  WHERE i.Status<>d.Status AND NOT(d.Status='POSTED' AND i.Status IN('REFUNDED','VOID'))
 ) THROW 51732,N'Chuyển trạng thái giao dịch không hợp lệ; chỉ POSTED được chuyển sang hoàn hoặc void.',1;

 IF EXISTS(
  SELECT 1 FROM inserted i JOIN deleted d ON d.TransactionId=i.TransactionId
  WHERE (ISNULL(i.RefundAmount,-1)<>ISNULL(d.RefundAmount,-1)
      OR ISNULL(i.RefundedAt,CONVERT(datetime2,'19000101'))<>ISNULL(d.RefundedAt,CONVERT(datetime2,'19000101'))
      OR ISNULL(i.RefundedBy,-1)<>ISNULL(d.RefundedBy,-1))
   AND NOT(d.Status='POSTED' AND i.Status IN('REFUNDED','VOID'))
 ) THROW 51733,N'Thông tin hoàn tiền chỉ được ghi khi chuyển giao dịch POSTED sang hoàn hoặc void.',1;

 IF EXISTS(
  SELECT 1 FROM inserted i JOIN deleted d ON d.TransactionId=i.TransactionId
  WHERE (d.Status='POSTED' AND i.Status='REFUNDED' AND (i.RefundAmount IS NULL OR i.RefundAmount<0 OR i.RefundAmount>i.Amount OR i.RefundedAt IS NULL))
     OR (d.Status='POSTED' AND i.Status='VOID' AND (ISNULL(i.RefundAmount,0)<>0 OR i.RefundedAt IS NOT NULL))
 ) THROW 51734,N'Số tiền hoàn hoặc thời điểm hoàn không khớp trạng thái giao dịch.',1;

 IF EXISTS(
  SELECT 1 FROM inserted i JOIN deleted d ON d.TransactionId=i.TransactionId
  WHERE (ISNULL(i.ReconciledAt,CONVERT(datetime2,'19000101'))<>ISNULL(d.ReconciledAt,CONVERT(datetime2,'19000101'))
      OR ISNULL(i.ReconciledBy,-1)<>ISNULL(d.ReconciledBy,-1))
   AND NOT(
    d.Status='POSTED' AND i.Status='POSTED' AND d.ServiceId IS NOT NULL
    AND d.ReconciledAt IS NULL AND d.ReconciledBy IS NULL
    AND i.ReconciledAt IS NOT NULL AND i.ReconciledBy=TRY_CONVERT(int,SESSION_CONTEXT(N'ActorId'))
    AND EXISTS(SELECT 1 FROM dbo.Users staff JOIN dbo.UserRoles ur ON ur.UserId=staff.UserId JOIN dbo.Roles r ON r.RoleId=ur.RoleId
     WHERE staff.UserId=i.ReconciledBy AND staff.Active=1 AND r.Code IN('FINANCE','ADMIN'))
   )
 ) THROW 51735,N'Đối soát chỉ được ghi một lần cho giao dịch POS đang POSTED bởi tài chính hoặc quản trị.',1;
END;
GO
