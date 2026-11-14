# POS ngoại tuyến

## Luồng hiện tại

- POS lấy danh mục dịch vụ và máy POS từ SQL Server khi đăng nhập có kết nối.
- App shell được cache bằng service worker. Danh mục POS tối thiểu được lưu ở trình duyệt để tiếp tục tạo giao dịch khi máy chủ tạm mất kết nối.
- Giao dịch được ghi vào localStorage theo UserId trước khi gửi. Mỗi mục có UUID riêng và UUID không đổi khi retry.
- Khi có kết nối, `/api/pos/quote` tra booking, account, gói, giá và dịch vụ bao gồm để hiển thị ước tính. Nhấn ghi sẽ gọi lại quote, sau đó ghi ngay qua `dbo.usp_SyncPOS`; thủ tục này chuyển nghiệp vụ sang `dbo.usp_PostPOS`. SQL vẫn tự tính lại giá và dịch vụ trong gói tại thời điểm ghi.
- `dbo.usp_SyncPOS` ghi giao dịch và biên nhận trong cùng transaction. Nếu một bước lỗi, cả hai cùng rollback; API chỉ xác nhận thành công khi đọc lại được cả giao dịch lẫn biên nhận.
- Biên nhận có UUID giao dịch duy nhất, nhân viên, thiết bị và thời điểm đồng bộ. Nhân viên POS chỉ tra cứu được 50 biên nhận gần nhất của chính tài khoản mình.
- SQL dùng `Transactions.ClientId` có unique constraint cùng khóa theo UUID để chống ghi lặp, kể cả hai request cùng lúc. Gửi lại đúng payload trả về giao dịch đã có; dùng UUID cũ với nội dung khác bị từ chối.
- `RegistrationId` có unique filtered index chỉ áp dụng với đăng ký khác `NULL`. Nhờ vậy một booking chỉ có một giao dịch phí hoạt động, trong khi booking vẫn có thể phát sinh nhiều giao dịch POS.
- Trình duyệt chỉ xóa mục hàng đợi khi API xác nhận thành công, trả giao dịch và biên nhận có cùng UUID, đồng thời hai bản ghi cùng `TransactionId`. Phản hồi thiếu hoặc không khớp giữ nguyên mục để retry. Nếu mất phản hồi sau khi SQL commit, gửi lại cùng UUID không tạo khoản phí hoặc biên nhận thứ hai.

## Kiểm tra

Chạy `npm run setup`, `npm start`; đăng nhập `pos@demo.local` với mật khẩu `Aurora123!`. Vào **POS ngoại tuyến**, lưu giao dịch, bật Network → Offline, tải lại trang và xác nhận mục vẫn có trong hàng đợi. Khi có mạng lại, bấm **Kết nối lại** nếu đang dùng cache, sau đó **Đồng bộ ngay**. Giao dịch được ghi ở SQL, hàng đợi giảm sau khi server xác nhận.

Chạy `npm run test:pos` để kiểm tra API và SQL trên database ngẫu nhiên riêng. Bộ kiểm thử xác nhận tính giá ở SQL, ghi biên nhận cùng giao dịch, retry UUID, hai request đồng thời, tra cứu biên nhận và phân quyền. Database tạm được xóa ở bước dọn dẹp.

## Giá và dịch vụ trong gói

Quote trực tuyến hiển thị hành khách, booking, gói, toàn bộ dịch vụ gói bao gồm, tổng phí đã ghi trong account, giá từng đơn vị, số lượng và tổng dự kiến. Nhấn **Làm mới báo giá** để lấy lại dữ liệu gói/giá mới nhất từ SQL Server; nút này tắt khi ngoại tuyến. Dịch vụ có trong `PackageServices` được đánh dấu không thu thêm và có đơn giá tính tiền 0; giá niêm yết vẫn hiển thị để đối chiếu. Biên nhận sau đồng bộ hiển thị booking, gói, nhân viên, thiết bị, số tiền giao dịch và tổng phí account sau khi ghi; không dùng giá từ trình duyệt để tính khoản phải thu.

## Giới hạn

Không tính giá khi offline; số tiền chỉ có sau khi SQL Server chấp nhận giao dịch. Biên nhận cũ trong chế độ offline là bản cache; khi trực tuyến, server luôn là nguồn dữ liệu chính. Không xóa dữ liệu trang web khi còn mục chờ trong hàng đợi.
