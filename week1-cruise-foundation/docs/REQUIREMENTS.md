# Đối chiếu với đề tài và kế hoạch

Phạm vi bảng dưới là yêu cầu/thiết kế theo tài liệu và bản gốc `cruise-sql`; các dòng “Chạy thật” mô tả mức của bản gốc. Riêng chức năng chi phí hành khách ở tuần 1 đã được triển khai trong repo này: tra cứu tài khoản/giao dịch/hoàn/hóa đơn theo booking của chủ tài khoản và gửi tranh chấp. Phạm vi hiện tại được cập nhật ở README.

Nguồn đối chiếu: De-Tai.docx và 1.docx do người dùng cung cấp. Phạm vi ứng dụng hành khách/POS là web responsive theo trao đổi trong chat và kế hoạch. Bảng này phân biệt phần chạy thật với tích hợp thiết bị/thu tiền được mô phỏng.

| Yêu cầu | Cách triển khai | Mức thực hiện |
|---|---|---|
| Chuyến nhiều ngày, tàu, khu vực | Ships, Zones, Cruises; tạo/sửa trong web | Chạy thật |
| Lịch trình, cảng, giờ đến/rời | Ports, Stops; giao diện Lịch trình | Chạy thật |
| Đổi lịch do thời tiết/vận hành | usp_ChangeStop, ItineraryChanges, Notifications | Chạy thật |
| Hoạt động: thời gian, địa điểm, sức chứa, phí | Activities, usp_SaveMaster, vw_ActivitySummary | Chạy thật |
| Tour bờ, nhà cung cấp | Activities.Kind=SHORE, Providers, Stops | Chạy thật |
| Nhóm, xe, hướng dẫn viên | TourGroups, GroupMembers, usp_AssignGroup | Chạy thật |
| Giờ tập trung/về tàu, trạng thái tour | StartsAt, ReturnAt, Status; màn hình tour/check-in | Chạy thật |
| Khách chưa về tàu | CheckIns.ReturnedAt, usp_ReturnToShip, vw_LatePassengers | Chạy thật |
| Đăng ký trước/trong chuyến | usp_Register với Bookings thuộc chuyến | Chạy thật |
| Sức chứa, chống trùng, danh sách chờ | UPDLOCK/HOLDLOCK, UNIQUE, usp_PromoteWaitlist | Chạy thật, đã kiểm thử đồng thời |
| Hủy, thời hạn, hoàn phí | Policy, usp_Cancel, RefundAmount | Chạy thật |
| Dịch vụ đã gồm/trả thêm | Packages, PackageServices, IncludedServiceId | Chạy thật |
| Định danh QR/thẻ/vòng tay | Identifiers; QR SVG và nhập/quét mã | QR thật; phần cứng thẻ/vòng tay mô phỏng |
| Check-in, chống lặp, ghi nhân viên/thiết bị | usp_CheckIn, CheckIns UNIQUE | Chạy thật |
| Tài khoản chi tiêu theo khách/cabin/booking | Accounts theo booking, booking liên kết khách/cabin; báo cáo tổng hợp | Chạy thật; không dùng chung một ví cabin |
| Chi phí hành khách (tuần 1) | `/api/passenger/finance`, tổng phí tạm tính/đã hoàn, giao dịch ròng, hóa đơn và khoản thanh toán; giới hạn theo chủ booking | Đã triển khai trong week1; thu tiền MOCK mô phỏng |
| POS ghi chi phí | usp_PostPOS, Transactions | Chạy thật |
| Void và hoàn tiền có quyền | usp_FinanceTransaction, role FINANCE/ADMIN | Chạy thật |
| Ngoại tuyến và đồng bộ | localStorage, cache POS, UUID, usp_SyncPOS, SyncReceipts | Chạy thật ở mức đơn giản |
| Đối soát | usp_Reconcile, ReconciledAt/By, biên nhận đồng bộ, trạng thái và audit | Chạy thật |
| Tranh chấp | Disputes, usp_Dispute, usp_ResolveDispute | Chạy thật |
| Hành khách gửi tranh chấp | `usp_SubmitPassengerDispute`, kiểm tra chủ giao dịch, unique filtered index cho tranh chấp OPEN, audit | Đã triển khai; tài chính xử lý trong màn hình Tài chính |
| Chốt tài khoản, thanh toán, hóa đơn | `usp_SettleAccount`, Invoices, Payments; chặn khi còn tranh chấp hoặc POS chưa đối soát | Ghi sổ thật; thu tiền mô phỏng `MOCK` |
| Xuất hóa đơn và CSV | In hóa đơn từ trình duyệt; xuất giao dịch CSV có bảo vệ công thức bảng tính | Chạy thật cho Finance/Admin |
| Thông báo theo chuyến và đã đọc | In-app Notifications, gửi theo chuyến, NotificationReads theo tài khoản | Chạy thật; không có push/SMS |
| Phản hồi hoạt động và sau chuyến | Feedback, CruiseFeedback; kiểm tra đã tham gia/kết thúc | Chạy thật |
| Dashboard doanh thu, tham gia, sức chứa, phản hồi | vw_Revenue, vw_ActivitySummary, báo cáo/cảnh báo | Chạy thật |
| Phân quyền 9 vai trò | Roles, UserRoles, cookie session, API và procedure kiểm tra quyền | Chạy thật |
| Chính sách, người dùng, định danh, thiết bị | Trang quản trị, usp_ManageUser, usp_SaveMaster | Chạy thật |
| Log đối soát và xuất dữ liệu | AuditLog, triggers, CSV | Chạy thật |
| Bảo vệ dữ liệu | Scrypt, quyền API, khóa ngoại, chống chèn SQL bằng literal hex | Chạy thật cho bản local |
| Giao diện hành khách/mobile/tablet/POS | React, CSS responsive, F12/device toolbar | Web responsive; không xuất APK |
| T-SQL trọng tâm | Procedures, TRY/CATCH, XACT_ABORT, transactions, views, function, triggers, index | Chạy trên SQL Server thật |
| BLE tùy chọn | Wearables, BLEReceivers, BLELocations, vw_BLELatest | Thiết kế và dữ liệu mẫu |
| Đặc tả, ERD, từ điển, hướng dẫn, kiểm thử | Các file docs và README | Đã cung cấp |

Giới hạn demo: account theo booking thay vì ví dùng chung cả cabin; tổng chi phí theo cabin được tính bằng tổng các tài khoản liên quan. Thông báo là in-app, người vận hành gửi nhắc tập trung/về tàu. Không có cổng thanh toán, phần cứng RFID/NFC/BLE thật hoặc đồng bộ xung đột phức tạp. Các lựa chọn này tương ứng phạm vi mô phỏng trong kế hoạch; nếu giảng viên yêu cầu native app/thiết bị thật thì cần bổ sung tích hợp riêng.
