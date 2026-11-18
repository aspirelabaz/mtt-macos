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

**Vì sao chọn File Provider thay vì FSKit:** File Provider ổn định hơn, có nhiều tài liệu hơn và hợp với cách MTP hoạt động (tải cả file, không đọc ghi ngẫu nhiên). FSKit chỉ nên xem xét sau nếu thật sự cần một ổ đĩa đúng nghĩa.

## Giai đoạn 4: Hoàn thiện và phân phối (3–5 ngày)

- [ ] Thử trên nhiều hãng: Samsung, Xiaomi, Pixel, Oppo (mỗi hãng có vài điểm lạ riêng khi chạy MTP)
- [ ] Đóng gói `libmtp.dylib` và `libusb.dylib` vào trong app. libmtp dùng giấy phép LGPL nên phải link động và ghi rõ giấy phép
- [ ] Tự chạy khi đăng nhập (`SMAppService`)
- [ ] Ký app, notarize và đóng gói thành DMG. Bước này cần tài khoản Apple Developer ($99/năm), chỉ cần nếu phát hành cho người khác
- [ ] Thêm log chẩn đoán để người dùng gửi khi gặp lỗi

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
