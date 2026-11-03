:ON ERROR EXIT
USE CruiseWeek1;
GO
SET XACT_ABORT ON;
GO
IF COL_LENGTH('dbo.Providers','ContactName') IS NULL ALTER TABLE dbo.Providers ADD ContactName nvarchar(100) NULL;
IF COL_LENGTH('dbo.Providers','Phone') IS NULL ALTER TABLE dbo.Providers ADD Phone varchar(30) NULL;
IF COL_LENGTH('dbo.Providers','Email') IS NULL ALTER TABLE dbo.Providers ADD Email varchar(150) NULL;
IF COL_LENGTH('dbo.Providers','Active') IS NULL ALTER TABLE dbo.Providers ADD Active bit NOT NULL CONSTRAINT DF_Providers_Active DEFAULT(1) WITH VALUES;
GO
IF OBJECT_ID('dbo.ShoreVehicles','U') IS NULL CREATE TABLE dbo.ShoreVehicles(VehicleId int IDENTITY PRIMARY KEY,ProviderId int NOT NULL REFERENCES dbo.Providers(ProviderId),Name nvarchar(100) NOT NULL,PlateNumber nvarchar(30) NULL,Capacity int NOT NULL CHECK(Capacity>0),Active bit NOT NULL DEFAULT(1),UNIQUE(ProviderId,Name));
IF OBJECT_ID('dbo.ShoreGuides','U') IS NULL CREATE TABLE dbo.ShoreGuides(GuideId int IDENTITY PRIMARY KEY,ProviderId int NOT NULL REFERENCES dbo.Providers(ProviderId),Name nvarchar(100) NOT NULL,Phone varchar(30) NULL,Active bit NOT NULL DEFAULT(1),UNIQUE(ProviderId,Name));
IF OBJECT_ID('dbo.ExcursionGroups','U') IS NULL CREATE TABLE dbo.ExcursionGroups(GroupId int IDENTITY PRIMARY KEY,ActivityId int NOT NULL REFERENCES dbo.Activities(ActivityId),Name nvarchar(100) NOT NULL,VehicleId int NULL REFERENCES dbo.ShoreVehicles(VehicleId),GuideId int NULL REFERENCES dbo.ShoreGuides(GuideId),Capacity int NOT NULL CHECK(Capacity>0),Active bit NOT NULL DEFAULT(1),UNIQUE(ActivityId,Name));
IF OBJECT_ID('dbo.ExcursionGroupMembers','U') IS NULL CREATE TABLE dbo.ExcursionGroupMembers(RegistrationId int NOT NULL PRIMARY KEY REFERENCES dbo.Registrations(RegistrationId),GroupId int NOT NULL REFERENCES dbo.ExcursionGroups(GroupId),AssignedBy int NOT NULL REFERENCES dbo.Users(UserId),AssignedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
GO
CREATE OR ALTER PROCEDURE dbo.usp_SaveShoreProvider @ActorId int,@ProviderId int=0,@Name nvarchar(100),@ContactName nvarchar(100)=NULL,@Phone varchar(30)=NULL,@Email varchar(150)=NULL,@Active bit=1 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code IN('SHORE','ADMIN')) THROW 51500,N'Chỉ quản lý tour bờ được thay đổi nhà cung cấp.',1;
 IF @Name IS NULL OR LEN(LTRIM(RTRIM(@Name)))=0 OR LEN(@Name)>100 THROW 51501,N'Tên nhà cung cấp không hợp lệ.',1;
 IF @ProviderId=0 BEGIN INSERT dbo.Providers(Name,ContactName,Phone,Email,Active) VALUES(LTRIM(RTRIM(@Name)),NULLIF(LTRIM(RTRIM(@ContactName)),''),NULLIF(LTRIM(RTRIM(@Phone)),''),NULLIF(LTRIM(RTRIM(@Email)),''),@Active); SET @ProviderId=SCOPE_IDENTITY(); END
 ELSE BEGIN
  IF NOT EXISTS(SELECT 1 FROM dbo.Providers WHERE ProviderId=@ProviderId) THROW 51502,N'Không tìm thấy nhà cung cấp.',1;
  IF @Active=0 AND EXISTS(SELECT 1 FROM dbo.Activities WHERE ProviderId=@ProviderId AND Kind='SHORE' AND Status IN('OPEN','DELAYED')) THROW 51503,N'Không thể ngừng nhà cung cấp đang có tour mở.',1;
  UPDATE dbo.Providers SET Name=LTRIM(RTRIM(@Name)),ContactName=NULLIF(LTRIM(RTRIM(@ContactName)),''),Phone=NULLIF(LTRIM(RTRIM(@Phone)),''),Email=NULLIF(LTRIM(RTRIM(@Email)),''),Active=@Active WHERE ProviderId=@ProviderId;
 END
 INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId) VALUES('Provider',@ProviderId,'UPDATE',@ActorId,CONCAT(N'Name=',@Name,N'; Active=',@Active),NEWID()); SELECT @ProviderId AS ProviderId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_SaveShoreVehicle @ActorId int,@VehicleId int=0,@ProviderId int,@Name nvarchar(100),@PlateNumber nvarchar(30)=NULL,@Capacity int,@Active bit=1 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code IN('SHORE','ADMIN')) THROW 51510,N'Chỉ quản lý tour bờ được thay đổi xe.',1;
 IF @Name IS NULL OR LEN(LTRIM(RTRIM(@Name)))=0 OR LEN(@Name)>100 OR @Capacity<1 OR @Capacity>1000 THROW 51511,N'Thông tin xe không hợp lệ.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Providers WHERE ProviderId=@ProviderId AND Active=1) THROW 51512,N'Nhà cung cấp không hoạt động.',1;
 IF @VehicleId=0 BEGIN INSERT dbo.ShoreVehicles(ProviderId,Name,PlateNumber,Capacity,Active) VALUES(@ProviderId,LTRIM(RTRIM(@Name)),NULLIF(LTRIM(RTRIM(@PlateNumber)),''),@Capacity,@Active); SET @VehicleId=SCOPE_IDENTITY(); END
 ELSE BEGIN
  IF EXISTS(SELECT 1 FROM dbo.ExcursionGroups g JOIN dbo.Activities a ON a.ActivityId=g.ActivityId WHERE g.VehicleId=@VehicleId AND (@Active=0 OR @ProviderId<>a.ProviderId OR @Capacity<g.Capacity)) THROW 51513,N'Xe đang được dùng trong nhóm hoặc không đủ chỗ.',1;
  UPDATE dbo.ShoreVehicles SET ProviderId=@ProviderId,Name=LTRIM(RTRIM(@Name)),PlateNumber=NULLIF(LTRIM(RTRIM(@PlateNumber)),''),Capacity=@Capacity,Active=@Active WHERE VehicleId=@VehicleId;
  IF @@ROWCOUNT=0 THROW 51514,N'Không tìm thấy xe.',1;
 END
 INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId) VALUES('ShoreVehicle',@VehicleId,'UPDATE',@ActorId,CONCAT(N'Name=',@Name,N'; Provider=',@ProviderId),NEWID()); SELECT @VehicleId AS VehicleId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_SaveShoreGuide @ActorId int,@GuideId int=0,@ProviderId int,@Name nvarchar(100),@Phone varchar(30)=NULL,@Active bit=1 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code IN('SHORE','ADMIN')) THROW 51520,N'Chỉ quản lý tour bờ được thay đổi hướng dẫn viên.',1;
 IF @Name IS NULL OR LEN(LTRIM(RTRIM(@Name)))=0 OR LEN(@Name)>100 THROW 51521,N'Thông tin hướng dẫn viên không hợp lệ.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Providers WHERE ProviderId=@ProviderId AND Active=1) THROW 51522,N'Nhà cung cấp không hoạt động.',1;
 IF @GuideId=0 BEGIN INSERT dbo.ShoreGuides(ProviderId,Name,Phone,Active) VALUES(@ProviderId,LTRIM(RTRIM(@Name)),NULLIF(LTRIM(RTRIM(@Phone)),''),@Active); SET @GuideId=SCOPE_IDENTITY(); END
 ELSE BEGIN
  IF EXISTS(SELECT 1 FROM dbo.ExcursionGroups g JOIN dbo.Activities a ON a.ActivityId=g.ActivityId WHERE g.GuideId=@GuideId AND (@Active=0 OR @ProviderId<>a.ProviderId)) THROW 51523,N'Hướng dẫn viên đang được phân công cho nhóm.',1;
  UPDATE dbo.ShoreGuides SET ProviderId=@ProviderId,Name=LTRIM(RTRIM(@Name)),Phone=NULLIF(LTRIM(RTRIM(@Phone)),''),Active=@Active WHERE GuideId=@GuideId;
  IF @@ROWCOUNT=0 THROW 51524,N'Không tìm thấy hướng dẫn viên.',1;
 END
 INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId) VALUES('ShoreGuide',@GuideId,'UPDATE',@ActorId,CONCAT(N'Name=',@Name,N'; Provider=',@ProviderId),NEWID()); SELECT @GuideId AS GuideId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_SaveShoreExcursion @ActorId int,@ActivityId int=0,@CruiseId int,@StopId int,@ProviderId int,@Name nvarchar(150),@GatherAt datetime2,@ReturnAt datetime2,@Capacity int,@Fee decimal(18,2),@Status varchar(20)='OPEN' AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code IN('SHORE','ADMIN')) THROW 51530,N'Chỉ quản lý tour bờ được thay đổi tour.',1;
 IF @Name IS NULL OR LEN(LTRIM(RTRIM(@Name)))=0 OR LEN(@Name)>150 OR @GatherAt IS NULL OR @ReturnAt<=@GatherAt THROW 51531,N'Tên tour hoặc khung giờ không hợp lệ.',1;
 IF @Capacity<1 OR @Capacity>100000 OR @Fee<0 OR @Fee>1000000000000 THROW 51532,N'Sức chứa hoặc phí tour không hợp lệ.',1;
 IF @Status NOT IN('OPEN','DELAYED','COMPLETED') THROW 51533,N'Trạng thái tour không hợp lệ.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Cruises WHERE CruiseId=@CruiseId AND Status IN('OPEN','SAILING')) THROW 51534,N'Chuyến không tồn tại hoặc đã kết thúc.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Stops s JOIN dbo.Providers p ON p.ProviderId=@ProviderId WHERE s.StopId=@StopId AND s.CruiseId=@CruiseId AND @GatherAt>=s.Arrival AND @ReturnAt<=s.Departure AND p.Active=1) THROW 51535,N'Nhà cung cấp không hoạt động hoặc giờ tập trung/về tàu nằm ngoài thời gian dừng cảng.',1;
 BEGIN TRY BEGIN TRAN;
  IF @ActivityId=0 BEGIN
   INSERT dbo.Activities(CruiseId,StopId,ProviderId,Name,Kind,StartsAt,EndsAt,ReturnAt,Capacity,Fee,Status) VALUES(@CruiseId,@StopId,@ProviderId,LTRIM(RTRIM(@Name)),'SHORE',@GatherAt,@ReturnAt,@ReturnAt,@Capacity,@Fee,@Status); SET @ActivityId=SCOPE_IDENTITY();
  END ELSE BEGIN
   IF NOT EXISTS(SELECT 1 FROM dbo.Activities WITH(UPDLOCK,HOLDLOCK) WHERE ActivityId=@ActivityId AND Kind='SHORE' AND Status<>'CANCELLED') THROW 51536,N'Không tìm thấy tour có thể sửa.',1;
   IF EXISTS(SELECT 1 FROM dbo.Registrations WHERE ActivityId=@ActivityId AND Status='CONFIRMED' AND @Capacity<(SELECT COUNT(*) FROM dbo.Registrations WHERE ActivityId=@ActivityId AND Status='CONFIRMED')) THROW 51537,N'Sức chứa mới thấp hơn số khách đã xác nhận.',1;
   IF EXISTS(SELECT 1 FROM dbo.ExcursionGroups WHERE ActivityId=@ActivityId AND Capacity>@Capacity) THROW 51538,N'Sức chứa tour thấp hơn sức chứa một nhóm.',1;
   IF EXISTS(SELECT 1 FROM dbo.ExcursionGroups WHERE ActivityId=@ActivityId AND Active=1 GROUP BY ActivityId HAVING SUM(Capacity)>@Capacity) THROW 51539,N'Tổng sức chứa các nhóm vượt sức chứa tour.',1;
   IF EXISTS(SELECT 1 FROM dbo.Activities WHERE ActivityId=@ActivityId AND CruiseId<>@CruiseId AND (EXISTS(SELECT 1 FROM dbo.Registrations WHERE ActivityId=@ActivityId) OR EXISTS(SELECT 1 FROM dbo.ExcursionGroups WHERE ActivityId=@ActivityId))) THROW 51539,N'Không thể chuyển chuyến khi tour đã có đăng ký hoặc nhóm.',1;
   IF EXISTS(SELECT 1 FROM dbo.ExcursionGroups g LEFT JOIN dbo.ShoreVehicles v ON v.VehicleId=g.VehicleId LEFT JOIN dbo.ShoreGuides d ON d.GuideId=g.GuideId WHERE g.ActivityId=@ActivityId AND ((g.VehicleId IS NOT NULL AND v.ProviderId<>@ProviderId) OR (g.GuideId IS NOT NULL AND d.ProviderId<>@ProviderId))) THROW 51539,N'Nhà cung cấp mới không khớp xe hoặc hướng dẫn viên của nhóm hiện tại.',1;
   UPDATE dbo.Activities SET CruiseId=@CruiseId,StopId=@StopId,ProviderId=@ProviderId,Name=LTRIM(RTRIM(@Name)),StartsAt=@GatherAt,EndsAt=@ReturnAt,ReturnAt=@ReturnAt,Capacity=@Capacity,Fee=@Fee,Status=@Status WHERE ActivityId=@ActivityId AND Kind='SHORE';
  END
  INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId) VALUES('ShoreTour',@ActivityId,IIF(@ActivityId=0,'INSERT','UPDATE'),@ActorId,CONCAT(N'Name=',@Name,N'; Provider=',@ProviderId,N'; Stop=',@StopId),NEWID());
 COMMIT; SELECT @ActivityId AS ActivityId;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_SaveExcursionGroup @ActorId int,@GroupId int=0,@ActivityId int,@Name nvarchar(100),@VehicleId int=NULL,@GuideId int=NULL,@Capacity int,@Active bit=1 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code IN('SHORE','ADMIN')) THROW 51540,N'Chỉ quản lý tour bờ được quản lý nhóm.',1;
 IF @Name IS NULL OR LEN(LTRIM(RTRIM(@Name)))=0 OR LEN(@Name)>100 OR @Capacity<1 THROW 51541,N'Thông tin nhóm không hợp lệ.',1;
 DECLARE @ProviderId int,@TourCapacity int; SELECT @ProviderId=ProviderId,@TourCapacity=Capacity FROM dbo.Activities WHERE ActivityId=@ActivityId AND Kind='SHORE' AND Status<>'CANCELLED';
 IF @ProviderId IS NULL THROW 51542,N'Tour không tồn tại hoặc đã hủy.',1;
 IF @Capacity>@TourCapacity THROW 51543,N'Sức chứa nhóm vượt quá sức chứa tour.',1;
 IF @VehicleId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.ShoreVehicles WHERE VehicleId=@VehicleId AND ProviderId=@ProviderId AND Active=1 AND Capacity>=@Capacity) THROW 51544,N'Xe không hoạt động, sai nhà cung cấp hoặc không đủ chỗ.',1;
 IF @GuideId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.ShoreGuides WHERE GuideId=@GuideId AND ProviderId=@ProviderId AND Active=1) THROW 51545,N'Hướng dẫn viên không hoạt động hoặc sai nhà cung cấp.',1;
 IF EXISTS(SELECT 1 FROM dbo.ExcursionGroups WHERE ActivityId=@ActivityId AND Active=1 AND GroupId<>@GroupId AND ((@VehicleId IS NOT NULL AND VehicleId=@VehicleId) OR (@GuideId IS NOT NULL AND GuideId=@GuideId))) THROW 51555,N'Xe hoặc hướng dẫn viên đã được gán cho nhóm khác trong tour này.',1;
 BEGIN TRY BEGIN TRAN;
  IF @GroupId=0 BEGIN
   IF (SELECT COALESCE(SUM(Capacity),0) FROM dbo.ExcursionGroups WHERE ActivityId=@ActivityId AND Active=1)+IIF(@Active=1,@Capacity,0)>@TourCapacity THROW 51546,N'Tổng sức chứa các nhóm vượt quá sức chứa tour.',1;
   INSERT dbo.ExcursionGroups(ActivityId,Name,VehicleId,GuideId,Capacity,Active) VALUES(@ActivityId,LTRIM(RTRIM(@Name)),@VehicleId,@GuideId,@Capacity,@Active); SET @GroupId=SCOPE_IDENTITY();
  END ELSE BEGIN
   IF NOT EXISTS(SELECT 1 FROM dbo.ExcursionGroups WITH(UPDLOCK,HOLDLOCK) WHERE GroupId=@GroupId AND ActivityId=@ActivityId) THROW 51547,N'Không tìm thấy nhóm của tour.',1;
   IF (SELECT COUNT(*) FROM dbo.ExcursionGroupMembers WHERE GroupId=@GroupId)>@Capacity THROW 51548,N'Sức chứa nhóm thấp hơn số khách đã gán.',1;
   IF @Active=0 AND EXISTS(SELECT 1 FROM dbo.ExcursionGroupMembers WHERE GroupId=@GroupId) THROW 51549,N'Gỡ khách khỏi nhóm trước khi ngừng nhóm.',1;
   IF @Active=1 AND (SELECT COALESCE(SUM(Capacity),0) FROM dbo.ExcursionGroups WHERE ActivityId=@ActivityId AND Active=1 AND GroupId<>@GroupId)+@Capacity>@TourCapacity THROW 51546,N'Tổng sức chứa các nhóm vượt quá sức chứa tour.',1;
   UPDATE dbo.ExcursionGroups SET Name=LTRIM(RTRIM(@Name)),VehicleId=@VehicleId,GuideId=@GuideId,Capacity=@Capacity,Active=@Active WHERE GroupId=@GroupId;
  END
  INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId) VALUES('ExcursionGroup',@GroupId,'UPDATE',@ActorId,CONCAT(N'Activity=',@ActivityId,N'; Name=',@Name),NEWID());
 COMMIT; SELECT @GroupId AS GroupId;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_AssignExcursionGuest @ActorId int,@RegistrationId int,@GroupId int=NULL AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.UserRoles ur JOIN dbo.Roles r ON r.RoleId=ur.RoleId WHERE ur.UserId=@ActorId AND r.Code IN('SHORE','ADMIN')) THROW 51550,N'Chỉ quản lý tour bờ được phân khách vào nhóm.',1;
 BEGIN TRY
  BEGIN TRAN;
  DECLARE @ActivityId int;
  -- Lock the registration like usp_CheckIn so assignment cannot race with a check-in scan.
  SELECT @ActivityId=a.ActivityId
  FROM dbo.Registrations r WITH(UPDLOCK,HOLDLOCK)
  JOIN dbo.Activities a ON a.ActivityId=r.ActivityId
  WHERE r.RegistrationId=@RegistrationId AND a.Kind='SHORE' AND r.Status='CONFIRMED';
  IF @ActivityId IS NULL THROW 51551,N'Chỉ lượt đăng ký tour bờ đã xác nhận mới được phân nhóm.',1;
  IF EXISTS(SELECT 1 FROM dbo.CheckIns WITH(UPDLOCK,HOLDLOCK) WHERE RegistrationId=@RegistrationId)
   THROW 51554,N'Không thể đổi nhóm của khách đã check-in để giữ nguyên trạng thái an toàn.',1;
  IF @GroupId IS NULL DELETE dbo.ExcursionGroupMembers WHERE RegistrationId=@RegistrationId;
  ELSE BEGIN
   DECLARE @GroupCapacity int; SELECT @GroupCapacity=Capacity FROM dbo.ExcursionGroups WITH(UPDLOCK,HOLDLOCK) WHERE GroupId=@GroupId AND ActivityId=@ActivityId AND Active=1;
   IF @GroupCapacity IS NULL THROW 51552,N'Nhóm không thuộc tour hoặc đã ngừng.',1;
   IF (SELECT COUNT(*) FROM dbo.ExcursionGroupMembers WHERE GroupId=@GroupId AND RegistrationId<>@RegistrationId)>=@GroupCapacity THROW 51553,N'Nhóm đã đủ chỗ.',1;
   MERGE dbo.ExcursionGroupMembers WITH(HOLDLOCK) AS t USING(SELECT @RegistrationId RegistrationId) AS s ON t.RegistrationId=s.RegistrationId WHEN MATCHED THEN UPDATE SET GroupId=@GroupId,AssignedBy=@ActorId,AssignedAt=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(RegistrationId,GroupId,AssignedBy) VALUES(@RegistrationId,@GroupId,@ActorId);
  END
  INSERT dbo.AuditLog(Entity,EntityId,Action,ActorId,Details,CorrelationId) VALUES('ExcursionGuest',@RegistrationId,IIF(@GroupId IS NULL,'REMOVE','ASSIGN'),@ActorId,CONCAT(N'Group=',COALESCE(CONVERT(nvarchar(20),@GroupId),N'—')),NEWID());
 COMMIT; SELECT @RegistrationId AS RegistrationId,@GroupId AS GroupId;
 END TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
GO
CREATE OR ALTER TRIGGER dbo.tr_ExcursionRegistrationCleanup ON dbo.Registrations AFTER UPDATE AS
BEGIN
 SET NOCOUNT ON;
 DELETE m FROM dbo.ExcursionGroupMembers m JOIN inserted i ON i.RegistrationId=m.RegistrationId JOIN dbo.Activities a ON a.ActivityId=i.ActivityId WHERE i.Status<>'CONFIRMED' OR a.Kind<>'SHORE';
END;
GO
