USE CruiseCoursework;
GO

SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RequireRole @StaffId int, @Role varchar(30) AS
BEGIN
    IF NOT EXISTS(SELECT 1 FROM UserRoles ur JOIN Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@StaffId AND r.Code IN(@Role,'ADMIN')) 
        THROW 51001, N'Không có quyền thực hiện nghiệp vụ.', 1;
    EXEC sys.sp_set_session_context @key=N'ActorId', @value=@StaffId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Register @BookingId int, @ActivityId int AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @CruiseId int, @Capacity int, @Fee decimal(18,2), @Start datetime2, @Status varchar(20), @AccountId int, @Actor int;
        
        SELECT @CruiseId=CruiseId, @Capacity=Capacity, @Fee=Fee, @Start=StartsAt, @Status=Status 
        FROM Activities WITH(UPDLOCK, HOLDLOCK) 
        WHERE ActivityId=@ActivityId;
        
        IF @CruiseId IS NULL OR @Status<>'OPEN' OR @Start<=SYSDATETIME() 
            THROW 51002, N'Hoạt động đã đóng hoặc đã bắt đầu.', 1;
            
        IF NOT EXISTS(SELECT 1 FROM Bookings WHERE BookingId=@BookingId AND CruiseId=@CruiseId) 
            THROW 51003, N'Đặt chỗ không thuộc chuyến đi này.', 1;
            
        SELECT @AccountId=AccountId 
        FROM Accounts WITH(UPDLOCK, HOLDLOCK) 
        WHERE BookingId=@BookingId AND Status='OPEN';
        
        IF @AccountId IS NULL 
            THROW 51004, N'Tài khoản đã chốt hoặc chưa tồn tại.', 1;
            
        IF EXISTS(SELECT 1 FROM Registrations WHERE BookingId=@BookingId AND ActivityId=@ActivityId) 
            THROW 51005, N'Đã có đăng ký cho hoạt động này.', 1;
            
        SELECT @Actor=p.UserId 
        FROM Bookings b 
        JOIN Passengers p ON p.PassengerId=b.PassengerId 
        WHERE b.BookingId=@BookingId;
        
        EXEC sys.sp_set_session_context @key=N'ActorId', @value=@Actor;
        
        DECLARE @State varchar(20) = CASE WHEN (SELECT COUNT(*) FROM Registrations WHERE ActivityId=@ActivityId AND Status='CONFIRMED') >= @Capacity THEN 'WAITLIST' ELSE 'CONFIRMED' END;
        
        INSERT Registrations(ActivityId, BookingId, Status) VALUES(@ActivityId, @BookingId, @State);
        DECLARE @RegistrationId int = SCOPE_IDENTITY();
        
        IF @State='CONFIRMED' 
            INSERT Transactions(AccountId, RegistrationId, Amount) VALUES(@AccountId, @RegistrationId, @Fee);
            
        COMMIT;
        SELECT @State AS Status, @RegistrationId AS RegistrationId;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Cancel @BookingId int, @RegistrationId int AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @ActivityId int, @Start datetime2, @AccountId int, @Status varchar(20);
        
        SELECT @ActivityId=ActivityId FROM Registrations WHERE RegistrationId=@RegistrationId AND BookingId=@BookingId;
        SELECT @Start=StartsAt FROM Activities WITH(UPDLOCK, HOLDLOCK) WHERE ActivityId=@ActivityId;
        SELECT @AccountId=AccountId FROM Accounts WITH(UPDLOCK, HOLDLOCK) WHERE BookingId=@BookingId AND Status='OPEN';
        SELECT @Status=Status FROM Registrations WITH(UPDLOCK, HOLDLOCK) WHERE RegistrationId=@RegistrationId;
        
        IF @AccountId IS NULL OR @Status IS NULL OR @Status='CANCELLED' 
            THROW 51006, N'Không thể hủy đăng ký này.', 1;
            
        IF @Start<DATEADD(hour, (SELECT CancelHours FROM Policy WHERE PolicyId=1), SYSDATETIME()) 
            THROW 51007, N'Đã qua hạn hủy.', 1;
            
        IF EXISTS(SELECT 1 FROM CheckIns WHERE RegistrationId=@RegistrationId) 
            THROW 51008, N'Đã check-in, không thể hủy.', 1;
            
        DECLARE @Actor int = (SELECT p.UserId FROM Bookings b JOIN Passengers p ON p.PassengerId=b.PassengerId WHERE b.BookingId=@BookingId);
        EXEC sys.sp_set_session_context @key=N'ActorId', @value=@Actor;
        
        UPDATE Registrations SET Status='CANCELLED' WHERE RegistrationId=@RegistrationId;
        UPDATE Transactions SET Status='REFUNDED' WHERE RegistrationId=@RegistrationId AND Status='POSTED';
        COMMIT;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CheckIn @ActivityId int, @Code varchar(100), @DeviceId int, @StaffId int AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON;
    EXEC usp_RequireRole @StaffId, 'ACTIVITY';
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @RegistrationId int;
        
        SELECT @RegistrationId=r.RegistrationId 
        FROM Identifiers i 
        JOIN Registrations r WITH(UPDLOCK, HOLDLOCK) ON r.BookingId=i.BookingId 
        JOIN Activities a ON a.ActivityId=r.ActivityId 
        WHERE i.Code=@Code AND i.Active=1 AND r.ActivityId=@ActivityId AND r.Status='CONFIRMED' AND a.Status IN('OPEN','DELAYED');
        
        IF @RegistrationId IS NULL 
            THROW 51009, N'Mã không hợp lệ hoặc khách chưa đăng ký.', 1;
            
        IF NOT EXISTS(SELECT 1 FROM Devices WHERE DeviceId=@DeviceId AND Kind='CHECKIN') 
            THROW 51010, N'Thiết bị không phải máy check-in.', 1;
            
        IF EXISTS(SELECT 1 FROM CheckIns WHERE RegistrationId=@RegistrationId) 
            THROW 51011, N'Khách đã check-in.', 1;
            
        INSERT CheckIns(RegistrationId, DeviceId, StaffId) VALUES(@RegistrationId, @DeviceId, @StaffId);
        COMMIT;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PostPOS @Code varchar(100), @ServiceId int, @Quantity int, @DeviceId int, @StaffId int, @ClientId uniqueidentifier AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON;
    EXEC usp_RequireRole @StaffId, 'POS';
    
    IF @Quantity<=0 OR @Quantity>100 
        THROW 51012, N'Số lượng phải từ 1 đến 100.', 1;
        
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @AccountId int, @PackageId int, @Price decimal(18,2);
        
        SELECT @AccountId=a.AccountId, @PackageId=b.PackageId 
        FROM Identifiers i 
        JOIN Bookings b ON b.BookingId=i.BookingId 
        JOIN Accounts a WITH(UPDLOCK, HOLDLOCK) ON a.BookingId=b.BookingId 
        WHERE i.Code=@Code AND i.Active=1;
        
        IF @AccountId IS NULL 
            THROW 51013, N'Mã khách không hợp lệ.', 1;
            
        IF EXISTS(SELECT 1 FROM Transactions WHERE ClientId=@ClientId)
        BEGIN
            IF NOT EXISTS(SELECT 1 FROM Transactions WHERE ClientId=@ClientId AND AccountId=@AccountId AND ServiceId=@ServiceId AND Quantity=@Quantity AND DeviceId=@DeviceId AND StaffId=@StaffId) 
                THROW 51014, N'Mã đồng bộ trùng nhưng nội dung khác.', 1;
            COMMIT; 
            SELECT 'ALREADY_SYNCED' AS Status; 
            RETURN;
        END;
        
        IF NOT EXISTS(SELECT 1 FROM Accounts WHERE AccountId=@AccountId AND Status='OPEN') 
            THROW 51015, N'Tài khoản đã chốt.', 1;
            
        IF NOT EXISTS(SELECT 1 FROM Devices WHERE DeviceId=@DeviceId AND Kind='POS') 
            THROW 51016, N'Thiết bị POS không hợp lệ.', 1;
            
        SELECT @Price=Price FROM Services WHERE ServiceId=@ServiceId;
        IF @Price IS NULL 
            THROW 51017, N'Dịch vụ không tồn tại.', 1;
            
        IF EXISTS(SELECT 1 FROM PackageServices WHERE PackageId=@PackageId AND ServiceId=@ServiceId) 
            SET @Price=0;
            
        INSERT Transactions(AccountId, ServiceId, Quantity, DeviceId, StaffId, ClientId, Amount) 
        VALUES(@AccountId, @ServiceId, @Quantity, @DeviceId, @StaffId, @ClientId, @Price*@Quantity);
        
        COMMIT; 
        SELECT 'SYNCED' AS Status;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Refund @TransactionId int, @StaffId int AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON; 
    EXEC usp_RequireRole @StaffId, 'FINANCE';
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @AccountId int = (SELECT AccountId FROM Transactions WHERE TransactionId=@TransactionId);
        
        IF NOT EXISTS(SELECT 1 FROM Accounts WITH(UPDLOCK, HOLDLOCK) WHERE AccountId=@AccountId AND Status='OPEN') 
            THROW 51018, N'Tài khoản đã chốt.', 1;
            
        UPDATE Transactions SET Status='REFUNDED' WHERE TransactionId=@TransactionId AND Status='POSTED';
        IF @@ROWCOUNT=0 
            THROW 51019, N'Giao dịch không còn hiệu lực.', 1;
            
        UPDATE Disputes SET Status='RESOLVED' WHERE TransactionId=@TransactionId;
        COMMIT;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Settle @AccountId int, @StaffId int AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON; 
    EXEC usp_RequireRole @StaffId, 'FINANCE';
    BEGIN TRY
        BEGIN TRAN;
        IF NOT EXISTS(SELECT 1 FROM Accounts WITH(UPDLOCK, HOLDLOCK) WHERE AccountId=@AccountId AND Status='OPEN') 
            THROW 51020, N'Tài khoản đã chốt hoặc không tồn tại.', 1;
            
        IF EXISTS(SELECT 1 FROM Disputes d JOIN Transactions t ON t.TransactionId=d.TransactionId WHERE t.AccountId=@AccountId AND d.Status='OPEN') 
            THROW 51021, N'Còn tranh chấp chưa xử lý.', 1;
            
        DECLARE @Total decimal(18,2) = (SELECT COALESCE(SUM(Amount),0) FROM Transactions WHERE AccountId=@AccountId AND Status='POSTED');
        
        INSERT Invoices(AccountId, Total) VALUES(@AccountId, @Total);
        DECLARE @InvoiceId int = SCOPE_IDENTITY();
        
        INSERT Payments(InvoiceId, Amount, Method) VALUES(@InvoiceId, @Total, 'DEMO');
        UPDATE Accounts SET Status='SETTLED' WHERE AccountId=@AccountId;
        
        COMMIT; 
        SELECT @InvoiceId AS InvoiceId, @Total AS Total;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ChangeStop @StopId int, @Arrival datetime2, @Departure datetime2, @Reason nvarchar(500), @StaffId int AS
BEGIN
    SET NOCOUNT ON; 
    SET XACT_ABORT ON; 
    EXEC usp_RequireRole @StaffId, 'ITINERARY';
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @CruiseId int, @OldArrival datetime2, @OldDeparture datetime2, @Start date, @End date;
        
        SELECT @CruiseId=s.CruiseId, @OldArrival=s.Arrival, @OldDeparture=s.Departure, @Start=c.StartDate, @End=c.EndDate 
        FROM Stops s WITH(UPDLOCK, HOLDLOCK) 
        JOIN Cruises c ON c.CruiseId=s.CruiseId 
        WHERE s.StopId=@StopId;
        
        IF @CruiseId IS NULL OR @Departure<=@Arrival OR CAST(@Arrival AS date)<@Start OR CAST(@Departure AS date)>@End 
            THROW 51022, N'Thời gian cảng không hợp lệ.', 1;
            
        IF EXISTS(SELECT 1 FROM Activities WHERE StopId=@StopId AND Status<>'CANCELLED' AND (StartsAt<@Arrival OR ReturnAt>@Departure)) 
            THROW 51023, N'Lịch mới xung đột với tour bờ. Điều chỉnh tour trước.', 1;
            
        INSERT ItineraryChanges(StopId, OldArrival, OldDeparture, NewArrival, NewDeparture, Reason, StaffId) 
        VALUES(@StopId, @OldArrival, @OldDeparture, @Arrival, @Departure, @Reason, @StaffId);
        
        UPDATE Stops SET Arrival=@Arrival, Departure=@Departure WHERE StopId=@StopId;
        
        INSERT Notifications(CruiseId, Message) VALUES(@CruiseId, N'Lịch trình cảng được cập nhật: ' + @Reason);
        COMMIT;
    END TRY 
    BEGIN CATCH 
        IF @@TRANCOUNT>0 ROLLBACK; 
        THROW; 
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Feedback @BookingId int, @RegistrationId int, @Rating int, @Comment nvarchar(500) AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM Registrations r JOIN CheckIns c ON c.RegistrationId=r.RegistrationId WHERE r.RegistrationId=@RegistrationId AND r.BookingId=@BookingId) 
        THROW 51024, N'Chỉ khách đã check-in mới được đánh giá.', 1;
        
    INSERT Feedback(RegistrationId, Rating, Comment) VALUES(@RegistrationId, @Rating, @Comment);
END;
GO

CREATE OR ALTER VIEW dbo.vw_ActivitySummary AS
SELECT a.*, 
    (SELECT COUNT(*) FROM Registrations r WHERE r.ActivityId=a.ActivityId AND r.Status='CONFIRMED') AS Registered,
    (SELECT COUNT(*) FROM Registrations r WHERE r.ActivityId=a.ActivityId AND r.Status='WAITLIST') AS Waiting,
    (SELECT COUNT(*) FROM CheckIns c JOIN Registrations r ON r.RegistrationId=c.RegistrationId WHERE r.ActivityId=a.ActivityId) AS CheckedIn,
    (SELECT AVG(CAST(f.Rating AS decimal(4,2))) FROM Feedback f JOIN Registrations r ON r.RegistrationId=f.RegistrationId WHERE r.ActivityId=a.ActivityId) AS Rating
FROM Activities a;
GO

CREATE OR ALTER VIEW dbo.vw_AccountSummary AS
SELECT a.AccountId, a.BookingId, a.Status, u.Name, c.Number AS Cabin,
    COALESCE((SELECT SUM(t.Amount) FROM Transactions t WHERE t.AccountId=a.AccountId AND t.Status='POSTED'),0) AS Total
FROM Accounts a 
JOIN Bookings b ON b.BookingId=a.BookingId 
JOIN Passengers p ON p.PassengerId=b.PassengerId 
JOIN Users u ON u.UserId=p.UserId 
JOIN Cabins c ON c.CabinId=b.CabinId;
GO

CREATE OR ALTER VIEW dbo.vw_LatePassengers AS
SELECT u.Name, a.Name AS Activity, s.Departure, a.ReturnAt, r.RegistrationId 
FROM CheckIns ci 
JOIN Registrations r ON r.RegistrationId=ci.RegistrationId 
JOIN Activities a ON a.ActivityId=r.ActivityId 
JOIN Stops s ON s.StopId=a.StopId 
JOIN Bookings b ON b.BookingId=r.BookingId 
JOIN Passengers p ON p.PassengerId=b.PassengerId 
JOIN Users u ON u.UserId=p.UserId 
WHERE a.Kind='SHORE' AND ci.ReturnedAt IS NULL AND SYSDATETIME()>=DATEADD(minute, -30, s.Departure);
GO

CREATE OR ALTER TRIGGER dbo.tr_BookingConsistency ON dbo.Bookings AFTER INSERT, UPDATE AS
BEGIN
    IF EXISTS(SELECT 1 FROM inserted b JOIN Cruises c ON c.CruiseId=b.CruiseId JOIN Cabins cb ON cb.CabinId=b.CabinId WHERE c.ShipId<>cb.ShipId) 
        THROW 51025, N'Cabin phải thuộc tàu của chuyến đi.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_ActivityConsistency ON dbo.Activities AFTER INSERT, UPDATE AS
BEGIN
    IF EXISTS(SELECT 1 FROM inserted a JOIN Cruises c ON c.CruiseId=a.CruiseId LEFT JOIN Zones z ON z.ZoneId=a.ZoneId LEFT JOIN Stops s ON s.StopId=a.StopId WHERE CAST(a.StartsAt AS date)<c.StartDate OR CAST(a.EndsAt AS date)>c.EndDate OR (a.Kind='ONBOARD' AND z.ShipId<>c.ShipId) OR (a.Kind='SHORE' AND (s.CruiseId<>a.CruiseId OR a.StartsAt<s.Arrival OR a.ReturnAt>s.Departure))) 
        THROW 51026, N'Hoạt động phải thuộc đúng tàu/chuyến và trong thời gian lịch trình.', 1;
END;
GO
