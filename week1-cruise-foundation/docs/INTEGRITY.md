# Nhật ký và toàn vẹn dữ liệu

Lớp toàn vẹn trong `database/09-integrity.sql` bảo vệ dữ liệu ngay tại SQL Server, kể cả khi thao tác không đi qua giao diện hoặc API. Các trigger kiểm tra quan hệ chéo bảng và hủy toàn bộ câu lệnh khi phát hiện dữ liệu không hợp lệ.

Các quy tắc chính:

- Cabin và khu vực phải thuộc cùng tàu với chuyến đang sử dụng; không được chuyển đối tượng đã dùng sang tàu khác.
- Giao dịch đăng ký phải thuộc đúng booking/account. Giao dịch dịch vụ phải dùng thiết bị `POS` và nhân viên đang hoạt động có vai trò `POS` hoặc `ADMIN`.
- Check-in mới chỉ nhận đăng ký `CONFIRMED`, thiết bị `CHECKIN` và nhân viên đúng bộ phận hoạt động/tour bờ.
- Hóa đơn phải bằng số dư ròng của giao dịch; thanh toán phải khớp hóa đơn và dùng phương thức được hỗ trợ.
- Account `SETTLED`, giao dịch, hóa đơn và thanh toán liên quan không được sửa trái quy tắc.
- Migration `database/23-financial-ledger-guard.sql` xem giao dịch là sổ cái chỉ ghi thêm: cấm xóa, khóa các cột gốc, chỉ cho chuyển `POSTED` sang `REFUNDED`/`VOID` theo metadata hợp lệ và chỉ cho đánh dấu đối soát một lần bởi FINANCE/ADMIN. Cơ sở dữ liệu cũng từ chối cập nhật giao dịch thuộc account đã chốt.

Audit của người dùng, vai trò, booking, đăng ký, giao dịch, hóa đơn, thanh toán, mã định danh, dịch vụ trong gói và chính sách lưu `ActorId`, `Details` và `CorrelationId`. Một nghiệp vụ nhiều bảng dùng chung `CorrelationId` để truy vết đầy đủ mà không tạo bản ghi audit trùng từ stored procedure.

`dbo.usp_VerifyDataIntegrity` quét lại các quan hệ quan trọng trên dữ liệu hiện có và báo lỗi nếu có vi phạm. Các index nghiệp vụ hỗ trợ tra audit, booking và giao dịch theo khóa thường dùng.

Chạy `npm run test:integrity` để tạo database `CruiseWeek1IntegrityTest`, kiểm tra các trigger, audit, bảo vệ tài chính và index, sau đó tự xóa database kiểm thử.
