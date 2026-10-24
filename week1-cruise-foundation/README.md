# Aurora Cruise · mốc nền tảng và tổng quan

Mốc hiện tại: đăng nhập/đăng xuất, mật khẩu băm scrypt, phiên 8 giờ, 8 vai trò, Tổng quan theo booking/chuyến, quản lý chuyến/lịch cảng, đăng ký, hủy, quản trị hệ thống, POS, chi phí hành khách và check-in. QR hành khách được cấp từ mã định danh đang hoạt động; API chỉ trả QR trong phạm vi booking của chủ tài khoản. Check-in kiểm tra mã, booking, trạng thái đăng ký, vai trò và thiết bị ở cả API lẫn SQL; mỗi đăng ký chỉ có một lượt check-in, lưu thời gian/nhân viên/thiết bị, và tour bờ có thể ghi nhận khách đã về tàu. POS tra booking, gói, dịch vụ bao gồm và giá qua SQL; bán trực tuyến ghi ngay vào account, offline giữ hàng đợi rồi đồng bộ theo UUID. Sau chuyến đi, hành khách có thể đánh giá hoạt động đã hoàn thành và chuyến đi; điểm trung bình cùng số lượt phản hồi được tổng hợp cho đội vận hành. Không phụ thuộc thư mục `cruise-sql` khi chạy.

## Chạy

Cần Node.js từ 18, SQL Server và sqlcmd trong PATH. Cài dependency QR bằng `npm ci`, rồi mở terminal ở thư mục này:

```powershell
npm run setup
npm start
```

Mở http://localhost:3001 hoặc nhấp đúp CHAY-WEB.cmd. Database riêng CruiseWeek1; không dùng CruiseCoursework của bản đầy đủ. Nếu dùng SQLEXPRESS, đặt $env:SQL_SERVER = '.\SQLEXPRESS' trước setup/start. Có thể đổi SQL_DATABASE và PORT; giữ cùng cấu hình khi setup/server/test. Dependency duy nhất là thư viện `qrcode` để tạo ảnh QR tại máy chủ; không cần bước build.

## Tài khoản

Mật khẩu demo: Aurora123! Mỗi tài khoản được lưu hash với salt riêng.

Trong dữ liệu mẫu, gói Premium bao gồm hoạt động Đêm nhạc trên biển; gói Tiêu chuẩn giữ mức phí niêm yết. Mức giá được chốt khi tạo đăng ký. Khi một đăng ký đã xác nhận bị hủy hoặc sức chứa hoạt động được tăng, booking chờ đầu tiên được tự động xác nhận và phí mới được ghi vào tài khoản.

| Vai trò | Email |
|---|---|
| Hành khách | guest1@demo.local đến guest20@demo.local |
| Điều phối | itinerary@demo.local |
| Hoạt động | checkin@demo.local |
| Tour bờ | shore@demo.local |
| POS | pos@demo.local |
| Tài chính | finance@demo.local |
| Vận hành | operations@demo.local |
| Quản trị | admin@demo.local |

## Mốc đã triển khai và phần tiếp theo

Đã hoàn tất lát cắt Tổng quan, đăng nhập/phân quyền, lịch trình, quản lý hoạt động trên tàu, đăng ký/danh sách chờ, hủy/hoàn phí, quản trị hệ thống và chi phí hành khách. Hành khách xem tài khoản theo booking, số dư tạm tính, giao dịch, hoàn phí, hóa đơn/thanh toán và gửi tranh chấp; API và stored procedure cùng xác minh quyền sở hữu. Tranh chấp đang mở chặn chốt tài khoản. Toàn vẹn dữ liệu chặn cabin hoặc hoạt động sai chuyến, giao dịch sai account, chứng từ sai tổng; chốt account tạo Invoice, Payment và trạng thái SETTLED trong cùng transaction, đồng thời chặn sửa tài chính sau chốt. POS đồng bộ từng giao dịch lên SQL Server qua API, xác nhận giá tại database, dùng UUID duy nhất để retry an toàn và lưu biên nhận đồng bộ trong cùng transaction.

## Tour bờ

Vai trò Quản lý tour bờ tạo, sửa và tìm tour; quản lý thông tin nhà cung cấp, xe, hướng dẫn viên; đặt giờ tập trung và giờ về tàu trong thời gian dừng cảng; tạo nhóm theo xe/hướng dẫn viên và gán khách đã xác nhận vào nhóm với kiểm tra sức chứa, quyền truy cập và audit.

## Hoạt động trên tàu

Vai trò Quản lý hoạt động có thể tạo, sửa, tìm kiếm và lọc hoạt động theo chuyến hoặc trạng thái; cấu hình thời gian, khu vực, sức chứa và phí. Hủy hoạt động chưa bắt đầu sẽ hủy các đăng ký còn hiệu lực, hoàn theo chính sách hiện hành, ghi lý do và audit. Không thể giảm sức chứa thấp hơn số lượt đã xác nhận hoặc hủy sau khi đã check-in.

## Thẻ hành khách và check-in

Hành khách mở mục **Thẻ hành khách** để xem mã QR và mã định danh của booking đang chọn. Nhân viên hoạt động hoặc tour bờ chọn chuyến, hoạt động, thiết bị check-in rồi quét QR hoặc nhập mã; SQL xác minh mã đang hoạt động và đăng ký đã xác nhận. Với tour bờ, nhân viên có thể ghi nhận khách đã về tàu sau khi check-in. Migration nằm trong `database/14-checkin.sql` và được setup tự chạy.

## POS và tài khoản chi tiêu

Nhân viên POS nhập mã khách, chọn dịch vụ và số lượng. Khi trực tuyến, `/api/pos/quote` tra booking, gói, giá niêm yết, dịch vụ đã gồm và tổng dự kiến; thao tác ghi tiếp tục được SQL xác thực và tính lại. Giao dịch được lưu vào account của booking, gồm dịch vụ, số lượng, thiết bị, nhân viên, UUID và số tiền thực thu. Dịch vụ nằm trong gói có đơn giá 0. Khi ngoại tuyến, giao dịch được xếp hàng; giá và account chỉ được xác nhận lúc đồng bộ.

## SQL và kiểm tra

Setup chạy 01-schema → 03-seed → 04-auth → 05-itinerary → 06-registration → 07-cancellation → 08-admin → 09-integrity → 10-pos-sync → 11-pos-receipts → 12-passenger-finance → 13-onboard-activities → 14-shore-excursions → 14-checkin → 15-feedback trên DB mới. Với DB CruiseWeek1 hiện có, setup giữ dữ liệu rồi chạy các migration để cập nhật nghiệp vụ. Seed không gọi usp_Register. Nếu dùng SSMS bật SQLCMD Mode. Sau khi chạy SQL bằng tay, chạy setup để cấp hash demo và cập nhật migration.

Chạy `npm run check`, `npm run test:auth`, `npm run test:integrity`, `npm run test:pos` và `npm run test:finance`. Test nghiệp vụ tự tạo database riêng rồi xóa sau khi chạy. Hướng dẫn: `docs/POS-OFFLINE.md`, `docs/PASSENGER-FINANCE.md`; chi tiết API/quyền: `docs/AUTH.md`.

## Code cần push

Push server.mjs, src, public, scripts, tests, database, docs, README.md, CHAY-WEB.cmd, package.json, package-lock.json và .gitignore. Không push .tmp, node_modules, .env hoặc log.

Các API chính: đăng nhập/đăng xuất, lịch trình, đăng ký/hủy, `/api/qr`, `/api/checkin`, `/api/checkin/:registrationId/return`, `/api/pos/quote`, `/api/pos/sync` và nhóm `/api/admin/*` cho dữ liệu quản trị, người dùng, danh mục, booking, gói dịch vụ, chính sách và mã định danh. Backend và SQL đều kiểm tra quyền; QR và dữ liệu hành khách bị giới hạn theo chủ booking. Cookie HttpOnly và SameSite=Strict; restart server cần đăng nhập lại. Bản học phần chạy localhost.

