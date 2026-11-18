# Kế hoạch: Duyệt file Android trên macOS qua MTP

Mục tiêu: cắm điện thoại Android vào Mac, chọn chế độ "Chuyển file", và xem, thao tác file trên điện thoại giống như trên Windows. Đích cuối là điện thoại hiện ở thanh bên Finder.

## Bối cảnh

- Android dùng giao thức **MTP** (Media Transfer Protocol) khi ở chế độ "Chuyển file".
- Windows có sẵn driver MTP. macOS thì không: Finder không hiện gì, Image Capture chỉ đọc ảnh qua PTP.
- Vì vậy phải tự viết phần kết nối MTP, và muốn hiện trong Finder thì cần thêm một File Provider extension.

## Kiến trúc tổng thể

```
┌─────────────────────┐       ┌──────────────────────────┐
│  Finder             │       │  App SwiftUI (menu bar + │
│  (thanh bên)        │       │  cửa sổ duyệt file)      │
└─────────┬───────────┘       └────────────┬─────────────┘
          │                                │
┌─────────▼───────────┐                    │
│ File Provider       │       XPC          │
│ Extension           ├──────────┐         │
└─────────────────────┘          │         │
                       ┌─────────▼─────────▼──────┐
                       │  Device Service           │  ← process duy nhất giữ kết nối USB
                       │  (MTPKit + libmtp)        │
                       └─────────────┬─────────────┘
                                     │ USB
                               📱 Android (MTP)
```

**Nguyên tắc chính:** chỉ một process được giữ kết nối USB. Cả app lẫn Finder extension đều gửi yêu cầu cho process đó qua XPC (cơ chế giao tiếp giữa các process trên macOS). Không làm vậy thì hai bên sẽ tranh nhau kết nối và lỗi.

## Cấu trúc thư mục dự kiến

```
mtt-macos/
├── Packages/MTPKit/      # Swift package
│   ├── Sources/CLibMTP/  #   module map trỏ tới libmtp của Homebrew
│   ├── Sources/MTPKit/   #   thư viện Swift bọc libmtp
│   └── Sources/mtt/      #   công cụ dòng lệnh để thử
├── App/                  # app SwiftUI
├── DeviceService/        # XPC service / helper
└── FileProviderExt/      # tích hợp Finder
```

---

## Giai đoạn 0: Chuẩn bị (khoảng nửa ngày)

- [x] Cài Xcode (Xcode 27, Swift 6.4)
- [x] `brew install libmtp` (libmtp 1.1.23)
- [x] `git init` và tạo cấu trúc thư mục như trên
- [x] Swift package `MTPKit` gọi được libmtp, lệnh `mtt detect` build và chạy được
- [x] Cắm điện thoại, chọn "Chuyển file", chạy `mtp-detect` và `mtt detect` để chắc máy nhận được

**Kết quả (2026-11-18):** Nhận được **Google Pixel 3 XL** (USB `18d1:4ee2`, chế độ MTP+ADB). Một vùng lưu trữ "Bộ nhớ trong dùng chung", dung lượng 55,4 GB, còn trống 3,3 GB, quyền đọc/ghi. libmtp mở được máy, không bị app khác chiếm.

**Xong khi:** `mtp-detect` hiện được tên điện thoại và các vùng lưu trữ (bộ nhớ trong, thẻ SD).

## Giai đoạn 1: Thư viện MTPKit + CLI (2–4 ngày)

Đây là phần lõi. Làm chắc ở đây thì các giai đoạn sau đỡ vất vả nhiều.

| Việc | Ghi chú |
|---|---|
| Bọc libmtp bằng Swift | Gọi hàm C qua `module.modulemap` |
| Phát hiện thiết bị | Lấy tên máy, hãng, số serial, danh sách vùng lưu trữ, dung lượng còn trống |
| Thao tác file | Liệt kê thư mục, tải về, đẩy lên, xoá, tạo thư mục, đổi tên |
| Báo tiến độ | Dùng callback của libmtp, cho phép huỷ giữa chừng |
| Cắm/rút nóng | Nghe sự kiện USB qua IOKit (`IOServiceAddMatchingNotification`) |
| An toàn luồng | Mọi lệnh MTP chạy tuần tự trên một hàng đợi riêng, vì libmtp không chịu được nhiều luồng gọi cùng lúc |
| CLI `mtt` | `mtt ls /DCIM`, `mtt pull`, `mtt push`, `mtt rm`, `mtt mkdir` |

**Xong khi:** Dùng CLI tải được một video vài GB về máy và đẩy được một thư mục lên điện thoại. Rút cáp giữa chừng thì báo lỗi rõ ràng, không bị treo.

### Tiến độ (2026-11-18)

- [x] `MTPKit`: mở máy, đọc thông tin, liệt kê vùng lưu trữ và thư mục, tìm theo đường dẫn
- [x] Tải về (file và cả thư mục), có thanh tiến độ, giữ ngày sửa, không ghi đè file đã có. Đo được khoảng **30 MB/s** (28 file / 265 MB trong 10 giây)
- [x] Huỷ bằng Ctrl-C: xoá file tải dở, tự khôi phục kết nối
- [x] Lệnh `mtt reset` khi điện thoại bị kẹt
- [x] Code cho đẩy lên, tạo thư mục, đổi tên, xoá, theo dõi cắm/rút (`mtt watch`)
- [x] Đã thử ghi trên máy thật, trong `/Download/mtt-test` (đã xoá sau khi thử):
  - đẩy lên file và thư mục lồng nhau có tên tiếng Việt, khoảng **28 MB/s**
  - tải ngược về, 5/5 file khớp checksum MD5
  - đổi tên file và thư mục (tên tiếng Việt)
  - huỷ khi đang đẩy lên: file dở bị xoá khỏi điện thoại
  - xoá file, xoá cả thư mục; từ chối xoá thư mục gốc, từ chối ghi trùng tên
- [x] `mtt watch` báo đúng Disconnected / Connected khi rút và cắm lại cáp
- [x] Rút cáp khi đang tải: báo "The device was disconnected.", không treo, xoá file tải dở. Cắm lại thì dùng bình thường
- [ ] Để sau: rút ngắn thời gian khôi phục sau khi huỷ (hiện khoảng 12 giây)
- [ ] Để sau: báo rút cáp nhanh hơn (hiện khoảng 10 giây, do libmtp chờ hết timeout USB). Ở Giai đoạn 2 dùng `USBWatcher` để báo ngay

**Giai đoạn 1 hoàn thành (2026-11-18).**

### Phát hiện kỹ thuật

- **libmtp reset cổng USB mỗi khi đóng kết nối** (cờ `FORCE_RESET_ON_CLOSE` trong bộ cờ Android). Điện thoại rớt khỏi USB khoảng 1 giây, lệnh mở tiếp theo nhận kết quả thiếu hoặc lỗi I/O. libmtp tự bật lại cờ này khi mở máy, nên phải tắt sau khi mở, qua hàm C trong [CMTPShim](Packages/MTPKit/Sources/CMTPShim/shim.c). Hàm này chép lại bố cục struct nội bộ của libmtp 1.1.23 và tự kiểm tra trước khi ghi: nếu Homebrew nâng cấp libmtp thì nó bỏ qua, `mtt info` sẽ cảnh báo.
- **Huỷ giữa chừng làm kẹt đường USB** của Android: mọi lệnh sau đó lỗi I/O hoặc trả về danh sách rỗng mà không báo lỗi. Cách xử lý là đóng phiên kèm reset rồi mở lại. Mất khoảng 12 giây; nếu không hạ timeout của libmtp thì mất tới 4 phút.
- **ID của file có thể đổi sau khi kết nối lại** (Android 10 trở lên cấp ID theo phiên). App và Finder extension phải nhận diện file theo **đường dẫn**, không lưu ID của MTP lâu dài.
- libmtp in nhiều dòng rác ra cả stdout lẫn stderr. CLI tắt chúng đi, trừ khi chạy với `-v`.
- Chrome đang mở một kết nối USB tới điện thoại (dò thiết bị cho `chrome://inspect`), và `adb` giữ interface ADB. Hiện không xung đột với MTP, ghi lại phòng khi sau này gặp lỗi.

## Giai đoạn 2: App duyệt file SwiftUI (4–6 ngày)

- [ ] Icon trên menu bar, báo khi cắm hoặc rút máy
- [ ] Cửa sổ duyệt file: xem dạng danh sách hoặc lưới, có đường dẫn (breadcrumb), sắp xếp, tìm kiếm
- [ ] Kéo thả hai chiều giữa Finder và cửa sổ app
- [ ] Hàng đợi chuyển file: thanh tiến độ, huỷ, thử lại
- [ ] Thumbnail cho ảnh và video (MTP có lệnh lấy thumbnail riêng)
- [ ] Hỗ trợ nhiều điện thoại cùng lúc và nhiều vùng lưu trữ
- [ ] Màn hình hướng dẫn khi chưa kết nối được: "Mở khoá máy", "Chọn chế độ Chuyển file", "Tắt OpenMTP / Android File Transfer"

**Xong khi:** Dùng app thay được OpenMTP cho nhu cầu hằng ngày.

### Tiến độ (2026-11-18)

Đã viết xong toàn bộ danh sách trên, project Xcode sinh bằng XcodeGen ([App/project.yml](App/project.yml)). App mở được, nhận Pixel 3 XL và liệt kê thư mục gốc. Các thao tác bằng chuột (mở thư mục, kéo thả, xoá, đổi tên, chuyển file qua giao diện) **đang chờ thử tay**.

- Mỗi điện thoại có một hàng đợi nền riêng: MTP chỉ cho một thao tác một lúc, nên khi đang chuyển file lớn, việc mở thư mục phải chờ (app hiện "Đang chờ lượt chuyển file hiện tại xong…").
- Mọi thao tác tìm file theo đường dẫn, cache ID thư mục theo `sessionGeneration`, tự tìm lại khi ID cũ hết hiệu lực.
- Trùng tên khi tải về hoặc chép lên thì tự đặt "tên (1).ext".
- Mở file (bấm đúp): tải vào thư mục tạm rồi mở bằng app mặc định.
- Kéo ra Finder: chỉ tải khi thả (SwiftUI `Transferable`).
- Đã thử tay các thao tác chuột (duyệt, lưới, mở file, kéo thả, đổi tên, xoá, tải về, menu bar): ổn.
- **Sao chép / Dán** (chuột phải hoặc ⌘C / ⌘V khi đang chọn trong danh sách file):
  - Sao chép: tải ngay vào thư mục tạm rồi đặt file lên clipboard, vì Finder chỉ dán được file đã có trên Mac.
  - Dán: chép file đang có trong clipboard lên điện thoại, vào thư mục hiện tại hoặc thư mục được chuột phải.
  - Sao chép trong app rồi dán sang thư mục khác trên điện thoại cũng chạy được, vì đi vòng qua bản tạm trên Mac.
  - Đang chờ thử tay.

## Giai đoạn 3: Hiện trong Finder (1–2 tuần, phần khó nhất)

| Việc | Ghi chú |
|---|---|
| Tách Device Service | Chuyển MTPKit vào một XPC service hoặc helper chạy nền (LaunchAgent) |
| File Provider Extension | Dùng `NSFileProviderReplicatedExtension` |
| Mỗi máy là một domain | Cắm vào thì gọi `NSFileProviderManager.add(domain)`, rút ra thì gỡ |
| Enumerator | Liệt kê thư mục theo yêu cầu, có cache cây thư mục |
| Đọc file | `fetchContents`: tải file từ điện thoại về khi người dùng mở |
| Ghi file | `createItem`, `modifyItem`, `deleteItem` |
| Ánh xạ ID | Chuyển object ID của MTP thành identifier của File Provider một cách ổn định |
| Xử lý ngắt kết nối | Báo lỗi đúng cách cho Finder, tránh hiện file "ma" sau khi đã rút cáp |

**Xong khi:** Cắm điện thoại vào thì Finder hiện mục tên điện thoại ở thanh bên. Mở ảnh, kéo thả và xoá file được như với một ổ đĩa.

### Tiến độ (2026-11-18)

**Đã chạy trong Finder** với Samsung S25 Edge, app ký bằng Personal Team `K5GD459T4W` và cài ở `/Applications/MTT.app`. Đã thử qua đường dẫn `~/Library/CloudStorage/MTT-<tên máy>`:
- duyệt thư mục; chép ra (video 104 MB khoảng 24 MB/s);
- chép vào file và thư mục lồng nhau (kiểm tra lại bằng CLI, MD5 khớp);
- đổi tên file và thư mục tiếng Việt có file con; tạo thư mục; xoá file và xoá cả thư mục.

Không còn job lỗi trong log của fileproviderd.

Thiết kế đã chọn (khác bản phác thảo ban đầu một chút):
- **App MTT vẫn là process duy nhất giữ USB**, không tách thành helper riêng. App được đăng ký làm launchd agent ([Agent.swift](App/MTT/Service/Agent.swift), `SMAppService.agent`): chạy khi đăng nhập (chỉ hiện trên menu bar) và được launchd tự khởi động khi extension cần.
- App mở dịch vụ XPC trên Mach service `TEAMID.local.mtt.service` ([ServiceHost.swift](App/MTT/Service/ServiceHost.swift)), chỉ nhận tiến trình ký cùng Team ID. Tên có tiền tố là App Group nên extension trong sandbox được phép kết nối.
- Giao thức XPC và kiểu dữ liệu nằm trong module `MTTShared` (không phụ thuộc libmtp). Gọi theo **serial điện thoại + đường dẫn**, không theo ID của MTP.
- Mỗi vùng lưu trữ của mỗi điện thoại là một domain, tức một mục ở thanh bên Finder ([DomainManager.swift](App/MTT/Service/DomainManager.swift)): thêm khi điện thoại sẵn sàng, gỡ khi rút cáp.
- Extension ([FileProviderExt/](FileProviderExt/)) dùng `NSFileProviderReplicatedExtension`:
  - Identifier là UUID ánh xạ tới đường dẫn, lưu ra file JSON trong App Group, và được cập nhật khi đổi tên.
  - File trao đổi qua thư mục `Transfers/` trong App Group, nên macOS không hỏi quyền truy cập dữ liệu của app khác.
  - Thay đổi phía điện thoại: Finder hỏi working set mỗi 60 giây và ngay sau mỗi thao tác qua app; extension liệt kê lại các thư mục đã xem gần đây rồi so sánh.
- Chưa hỗ trợ: di chuyển giữa các thư mục trong Finder (báo lỗi "không hỗ trợ"), tiến độ chi tiết khi Finder chép file.

### Các lỗi đã gặp khi thử thật, và cách sửa

- **Bảo vệ dữ liệu app trên macOS mới**: app MTT (không sandbox) không được truy cập App Group container (TCC `SystemPolicyAppData`). Giờ không dùng thư mục chung nữa: extension mở file trong sandbox của nó và **gửi file descriptor qua XPC**; app đọc/ghi bằng `LIBMTP_Get_File_To_File_Descriptor` / `LIBMTP_Send_File_From_File_Descriptor`.
- **Domain File Provider phải được người dùng bật** trong Cài đặt > Cài đặt chung > Mục đăng nhập & Tiện ích mở rộng > File Providers. Chưa bật thì fileproviderd báo "Sync is not enabled" (-2011).
- **Bảng ID bị mất** khi có nhiều tiến trình extension cùng ghi file JSON, nên Finder tưởng file đã bị xoá phía điện thoại. Đã chuyển sang SQLite (WAL, `busy_timeout`).
- **Đổi tên rồi tra theo tên mới thất bại**: `LIBMTP_Set_Object_String` không cập nhật cache object của libmtp trong phiên. Giờ dùng `LIBMTP_Set_File_Name`. `modifyItem` cũng dựng kết quả từ dữ liệu đọc trước khi đổi tên.
- **Đổi tên thư mục tiếng Việt làm hỏng đường dẫn của file con**: `substr` của SQLite đếm theo code point, còn `String.count` của Swift đếm theo grapheme. Đã sửa, và tên gửi lên điện thoại được chuẩn hoá về NFC.
- Lỗi trả về cho File Provider chỉ được thuộc domain Cocoa hoặc NSFileProvider; lỗi khác giờ được đổi thành lỗi Cocoa.
- Đổi cách sinh identifier thì phải xoá domain cũ: tăng `MTTDomainSchema` trong [DomainManager.swift](App/MTT/Service/DomainManager.swift).

- **`ptpcamerad` (Ảnh / Image Capture) chiếm điện thoại Samsung khi cắm lại.** Samsung khai báo interface MTP là loại "still image", nên macOS tự gắn vào, và libmtp không chiếm được. Mỗi lần mở thất bại còn để rò một kết nối USB bên trong libmtp. Cách xử lý:
  - App phát hiện việc này qua IOKit và có nút "Giải phóng". Nút này tắt `ptpcamerad`: gửi SIGTERM, nếu sau nửa giây vẫn còn thì gửi SIGKILL (nó bỏ qua SIGTERM). Sau đó app khởi động lại để dọn các kết nối bị rò.
  - Có tuỳ chọn tự làm việc này trước lần mở đầu tiên mỗi khi cắm máy.
  - macOS bật lại `ptpcamerad` ngay, nhưng nó không chiếm được vì MTT đã giữ máy.
- **Kéo file ra Finder thành file "data" không có đuôi**: thiếu `.suggestedFileName` trong `Transferable`. Đã sửa.

**Giai đoạn 3 hoàn thành (2026-11-18).** Người dùng đã thử trên Finder: duyệt, chép vào/ra, rút cáp và cắm lại.

### Ghi chú khi phát triển

- Sau mỗi lần build: chép vào `/Applications/MTT.app` rồi khởi động lại (`pkill -x MTT; open /Applications/MTT.app`). App tự chuyển sang chạy dưới launchd.
- Muốn dùng CLI `mtt` thì phải tạm tắt agent, nếu không launchd sẽ bật lại app và hai bên tranh nhau USB: `launchctl disable gui/$(id -u)/local.mtt.agent; pkill -x MTT`, xong thì `launchctl enable …` và `launchctl kickstart …`.
- Trong zsh, `log` là lệnh có sẵn của shell: phải gọi `/usr/bin/log show …`.

**Vì sao chọn File Provider thay vì FSKit:** File Provider ổn định hơn, có nhiều tài liệu hơn và hợp với cách MTP hoạt động (tải cả file, không đọc ghi ngẫu nhiên). FSKit chỉ nên xem xét sau nếu thật sự cần một ổ đĩa đúng nghĩa.

## Giai đoạn 4: Hoàn thiện và phân phối (3–5 ngày)

App chỉ dùng cá nhân, nên bỏ phần notarize / DMG. Người dùng đã chọn làm cả 4 việc dưới đây.

- [x] Đã thử trên 2 hãng: Pixel 3 XL và Samsung S25 Edge
- [x] **Đóng gói libmtp 1.1.23 + libusb 1.0.30 vào app** ([Vendor/libmtp](Vendor/libmtp/README.md)), install name đổi sang `@rpath`, link động (LGPL, có kèm giấy phép). `brew upgrade` không còn ảnh hưởng. Build Release và cài bằng [scripts/install.sh](scripts/install.sh)
- [x] Tự chạy khi đăng nhập (`SMAppService` agent, đã làm ở Giai đoạn 3)
- [x] **Log chẩn đoán**:
  - `os.Logger` với subsystem `local.mtt`, chia nhóm `device`, `transfer`, `service`, `domain`, `agent`, `fileprovider`, `mtp`; mọi yêu cầu XPC đều ghi kèm thời gian xử lý
  - menu bar có lệnh "Xuất log chẩn đoán…": lưu log 2 giờ gần nhất ra Desktop
  - đọc tay: `/usr/bin/log show --predicate 'subsystem == "local.mtt"' --info --last 1h`
- [x] **Huỷ nhanh hơn**:
  - còn ≤ 48 MB thì nhận hoặc gửi nốt rồi bỏ kết quả: khoảng 1 giây, không phải reset
  - còn nhiều hơn thì reset với timeout ngắn hơn: khoảng 10 giây (trước đây 12,9 giây). Không xuống thấp hơn được vì lần thử đầu tiên khi mở phiên luôn chờ 5 giây (`USB_START_TIMEOUT`, biên dịch sẵn trong libmtp)
- [x] **Rút cáp nhanh hơn**: `abortPendingIO()` hạ timeout ngay khi USB báo điện thoại đã rời. *Chưa thử với cáp thật.*
- [x] **Tự chữa lành**:
  - khi kết nối lại, phải liệt kê được thư mục gốc mới coi là thành công
  - lệnh liệt kê vẫn lỗi sau khi thử lại thì tự kết nối lại
  - nếu kết nối lại vẫn thất bại mà điện thoại còn cắm thì mở lại từ đầu
  - trước mỗi lần mở lại thì giải phóng điện thoại khỏi `ptpcamerad` (nếu đã bật tuỳ chọn)
- [x] **Finder: di chuyển file và thư mục giữa các thư mục** (MTP MoveObject), đã thử trên Pixel
- [x] **Finder: tiến độ theo byte** khi chép vào/ra, truyền bằng cơ chế `Progress` của NSXPCConnection; nút huỷ của Finder huỷ luôn lượt truyền. Log xác nhận progress đã được gắn

Còn để sau: tự build lại libmtp để rút ngắn `USB_START_TIMEOUT`; cắt / dán (di chuyển) trong cửa sổ app.

---

## Rủi ro chính

| Rủi ro | Cách xử lý |
|---|---|
| App khác chiếm USB (OpenMTP, Android File Transfer, Android Studio) | Phát hiện và báo cho người dùng biết app nào đang chiếm |
| File Provider khó debug | Làm xong Giai đoạn 2 trước để có app dùng được, sau đó mới đụng vào Finder |
| libmtp chậm hoặc không ổn với vài máy | Nếu cần thì về sau viết lại MTP thuần Swift trên IOUSBHost. Vì đã có lớp MTPKit bọc bên ngoài nên không phải sửa phần còn lại |
| MTP không đọc ghi ngẫu nhiên được | Sửa file phải tải cả file về rồi đẩy lên lại, nên Finder extension phải có cache |
| Phải bấm "Cho phép" trên điện thoại | Điện thoại phải đang mở khoá. App hiện hướng dẫn rõ khi chưa có quyền |

## Thời gian ước tính

| Giai đoạn | Thời gian |
|---|---|
| 0. Chuẩn bị | khoảng nửa ngày |
| 1. MTPKit + CLI | 2–4 ngày |
| 2. App SwiftUI | 4–6 ngày |
| 3. Tích hợp Finder | 1–2 tuần |
| 4. Hoàn thiện và phân phối | 3–5 ngày |
| **Tổng** | **khoảng 3–5 tuần** |

Riêng Giai đoạn 0–2 mất khoảng 1,5 tuần là đã có app dùng được.

## Quyết định đã chốt

- **App chỉ dùng cá nhân.** Giai đoạn 4 bỏ phần notarize, đóng gói DMG và thử nhiều hãng điện thoại. Không cần tài khoản Apple Developer trả phí: dùng Apple ID miễn phí (Personal Team) trong Xcode để ký app chạy trên máy mình. Riêng File Provider extension cần App Group, phải kiểm tra lại ở Giai đoạn 3 xem Personal Team có đủ không.
- **Thử với điện thoại thật:** khi cần thử, Claude sẽ báo để cắm điện thoại vào (chọn chế độ "Chuyển file" và mở khoá máy).
