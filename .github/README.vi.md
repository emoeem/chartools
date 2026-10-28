<div align="center">

<img src="assets/images/logo.png" width="150" alt="Jev 聊天助手" />

# Jev 聊天助手 · Nhánh cục bộ

**“Trợ lý đồng hành hội thoại” cài trên điện thoại: hiểu người kia trong các ứng dụng chat được hỗ trợ, cho biết nên trả lời thế nào, điền vào ô nhập bằng một chạm; bạn tự quyết định có gửi hay không.**

> **Đây là một nhánh cục bộ được phát triển dựa trên Jev Chat Assistant** (tên gói `com.jev.probe`, phiên bản hiện tại 2.0 đang phát triển). Đây **không phải kho gốc và không phải bản phát hành của tác giả gốc**, chỉ được build và dùng tại máy, không phát hành APK. Kho gốc: [jev-chat/jev-chat-jarvis](https://github.com/jev-chat/jev-chat-jarvis). Ghi nguồn theo yêu cầu của [NOTICE](../NOTICE); không dùng tên hay tên miền của dự án gốc để ngụ ý tác giả gốc chứng thực.

[![Version](https://img.shields.io/badge/%E7%89%88%E6%9C%AC-2.0%20dev-1f6feb?style=flat-square)](../cn/CHANGELOG.md)
[![Android](https://img.shields.io/badge/Android-11%2B-3DDC84?style=flat-square&logo=android&logoColor=white)](#bắt-đầu-nhanh)
[![License](https://img.shields.io/badge/license-MIT-1f6feb?style=flat-square)](../LICENSE)

[Hướng dẫn tính năng đầy đủ (tiếng Trung)](../cn/docs/feature-guide.md) · [Nhật ký thay đổi (tiếng Trung)](../cn/CHANGELOG.md) · [Người đóng góp](CONTRIBUTORS.md) · [Trang web gốc](https://chatjevs.com) · [Hướng dẫn cài đặt gốc](https://chatjevs.com/guides/android-setup.html) · [Bản macOS gốc](https://github.com/jev-chat/jev-chat-jarvis-mac) · [Bản Windows gốc](https://github.com/jev-chat/jev-chat-windows)

[简体中文](README.md) · [English](README.en.md) · **Tiếng Việt**

</div>

## Nhánh này thay đổi những gì

Nhánh này tiếp tục phát triển dựa trên bản gốc v1.7, toàn bộ thay đổi nằm trong kho này; danh sách đầy đủ ở các mục "chưa phát hành" trong [nhật ký thay đổi](../cn/CHANGELOG.md) (tiếng Trung), mô tả tính năng đầy đủ ở [hướng dẫn tính năng](../cn/docs/feature-guide.md) (tiếng Trung):

- **Lớp thu thập:** thêm adapter Telegram và TIM; WeChat đi theo đường chỉ đọc "chụp màn hình + OCR trên máy" (màu bong bóng quyết định bên trái/phải); gom nhóm OCR, gán người nói, khử trùng lặp trả lời gần đây.
- **Kho tri thức:** nhập tài liệu trên máy (PDF / Word / EPUB / trang web; bản scan tự chuyển sang OCR trên máy), gói kỹ năng (Agent Skills, tự khớp theo hội thoại), hồ sơ liên hệ và sổ ghi.
- **Thư viện nhân vật:** nhân vật trở thành thư viện do người dùng tự quản (tạo / đổi tên / nhân bản / xoá / nhập / xuất / khôi phục mẫu), thay cho ba mẫu cứng, với 14 thẻ khởi đầu (quan hệ / bán hàng / công sở / chăm sóc khách hàng / đời thường); hỗ trợ nhân vật riêng cho từng liên hệ và các khoá chủ đề, giới hạn cứng, "tránh nói", từ an toàn, đèn vàng, câu ví dụ.
- **Thư viện chuyên gia (danh mục chỉ đọc 331 vị):** một "chuyên gia" = một phần thân nhân vật + ảnh đại diện, mô tả một dòng, thẻ, phân loại và số lần dùng. Ngoài các mẫu viết tay, APK còn đóng gói danh mục lấy từ [MichengAI/dsh-agency-agents](https://github.com/MichengAI/dsh-agency-agents): 331 vị thuộc 22 lĩnh vực (kỹ thuật / thiết kế / marketing / bán hàng / tài chính / y tế / pháp lý / học thuật …), và **chỉ vào thư viện của bạn khi bạn bấm chọn**. Phần nội dung nhân vật trong Cài đặt vẫn là nguồn duy nhất — không lưu "đang chọn chuyên gia nào" — còn ảnh, mô tả, thẻ, phân loại và số lần dùng chỉ dùng để duyệt và sắp xếp, không bao giờ vào prompt.
- **Tạo thủ công:** nút tạo lại trên đầu thẻ, trong menu nhấn giữ và trong thông báo thường trực; có ảnh chụp hiện tại thì tạo lại ngay, không có thì đọc màn hình một lần, đều không được thì nói rõ lý do; một vòng bị kẹt quá 8 giây có thể bị tiếp quản thủ công.
- **Độ tự nhiên của trả lời (P0):** bản nháp đầu tiên được viết *sau* khi có phán đoán (dự phòng viết mù sau 2 giây); quan hệ ưu tiên "quan hệ của liên hệ hơn quan hệ toàn cục"; hợp đồng chiến lược ứng viên biết số lượng (xin 2 ứng viên không còn đòi 3 chiến lược); khoá nhân vật mới "tránh nói" tách "dừng cả vòng khi đối phương nhắc tới" khỏi "trả lời của tôi không được nói ra"; phán đoán có độ tin cậy thấp chỉ còn là gợi ý, không bị nói như sự thật.
- **Lớp can thiệp tùy chọn:** tăng cường chỉ đọc qua LSPosed / Vector — mặc định tắt, bật theo từng ứng dụng, không đọc được thì lập tức quay về đường accessibility và ghi lý do vào Trace.
- **Ngữ cảnh và ghi nhớ:** cửa sổ ngữ cảnh trả lời 10 → 20 tin nhắn; sửa ngưỡng khớp kho tri thức (một gói kỹ năng đơn lẻ trước đây không thể đạt tới về mặt toán học); nhắc rõ trên thẻ khi ghi nhớ chưa được kích hoạt.
- **Giao diện:** bong bóng dính mép màn hình, thẻ ứng viên và phán đoán phân tầng (chi tiết có thể thu gọn), trang cài đặt chia nhóm, mức đẩy (tự động / giữ lại / tự nhiên / đẩy mạnh).
- **API và sinh văn bản:** thêm preset DeepSeek cho API phán đoán (tự chuyển sang "chế độ chat OpenAI"), tham số phạt lặp, khóa đèn vàng trên thẻ nhân vật.
- **Ổn định và an toàn (đợt gia cố):** sửa lỗi làm sập dịch vụ trợ năng của WeChat khi tạo thủ công đúng lúc đang chuyển cửa sổ; tạo thủ công giờ tiếp quản được vòng bị kẹt, đọc null tạm thời không còn xả hội thoại, số đếm trên viên nhộng thu gọn không còn treo vĩnh viễn; khóa cache trả lời nới lên mười bốn thành phần (nhân vật theo liên hệ, ngôn ngữ, độ dài, tham số lấy mẫu và soát chứng cứ đều có), client phán đoán/soạn thành singleton cấp dịch vụ — phân tích lặp không còn trả lại tiền gọi phán đoán; ghi đĩa và nhập hàng loạt trên ba trang cài đặt / kho tri thức / chuyên gia đã chuyển ra khỏi luồng chính; quét điểm ảnh chạy ngoài luồng, kiểm tra danh tính có hộp thời gian 400ms khi streaming; các script đánh giá trong `tools/` đều đi qua rào SSRF và đường dẫn (`tools/jev/safeguards.py`).

Tác giả gốc không tham gia và không bảo chứng cho các thay đổi này; tính năng và tài liệu gốc xem tại [kho gốc](https://github.com/jev-chat/jev-chat-jarvis).


## Lý do nên dùng

- **Nó phân tích trước, rồi mới soạn câu trả lời.** Hầu hết công cụ chỉ yêu cầu mô hình soạn thẳng một câu trả lời. Jev trước tiên dùng mô hình phân tích để xác định ý định thật của đối phương, mức độ nguy hiểm, có nên trả lời ngay hay không, rồi mới soạn câu trả lời dựa trên kết quả đó.
- **Mặc định không can thiệp vào ứng dụng chat của bạn.** Mặc định không hook, không sửa gói, không sử dụng API hay tài khoản của bất kỳ ứng dụng nào, không đọc cơ sở dữ liệu; chỉ dùng dịch vụ trợ năng của hệ thống để đọc cuộc trò chuyện đang hiển thị trên màn hình. Ngoài ra còn một lớp tăng cường **tùy chọn** qua LSPosed / Vector — tắt theo mặc định, bật riêng cho từng ứng dụng, và đọc không được thì lập tức quay về đường trợ năng.
- **Quyền gửi luôn thuộc về bạn.** Ứng dụng chỉ điền câu trả lời vào ô nhập, không bao giờ tự gửi, không can thiệp vào việc chuyển tiền, lì xì hoặc thu tiền.
- **Một lõi, nhiều nền tảng.** QQ, TIM và X đã chạy thử trên thiết bị thật; 飞书 bổ sung nội dung chính bằng OCR, WhatsApp được kiểm chứng bằng dữ liệu ghi màn hình. Thêm một ứng dụng chỉ cần viết một adapter vài chục dòng.
- **Nó hiểu những người và việc liên quan đến bạn.** Cơ sở tri thức cục bộ và hồ sơ liên hệ tự động đưa các ghi chú phù hợp cùng lịch sử trò chuyện của người đó vào quá trình phân tích, giúp câu trả lời không mâu thuẫn với thiết lập của bạn.
- **Bạn tự cấu hình API.** Địa chỉ, khóa và mô hình cho ba luồng phân tích, trả lời và thị giác đều có thể điền riêng. Khi phân tích, nội dung trò chuyện và thông tin nền đang bật sẽ được gửi tới nhà cung cấp mô hình mà bạn cấu hình; người duy trì nhánh này không vận hành máy chủ trung gian.
- **Có thể kiểm soát dữ liệu lưu trên máy.** Khóa, cơ sở tri thức và lịch sử tùy chọn nằm trong không gian riêng của ứng dụng; ảnh chụp màn hình chỉ được OCR trên máy và không tải lên. Cách nhà cung cấp bên thứ ba xử lý nội dung nhận được tuân theo chính sách quyền riêng tư của họ.

## Hỗ trợ nền tảng

| Nền tảng | Trạng thái | Cách thu thập | Ghi chú |
|---|---|---|---|
| QQ Android | ✅ Hỗ trợ đầy đủ từ đầu đến cuối | Đọc node bằng dịch vụ trợ năng | Đã kiểm thử trên 9.3.50 (trò chuyện nhóm); 1v1 được suy luận theo cùng cấu trúc |
| TIM (`com.tencent.tim`) | 🧪 Chưa xác minh phần đọc nội dung | Đọc node bằng dịch vụ trợ năng | Quy tắc được lấy mẫu trên thiết bị thật với TIM 4.1.0 (versionCode 4050). viewId của TIM bị AndResGuard làm rối (nội dung `9u`, bong bóng `n9e`, biệt danh `9w`, ô nhập `input`) nên có thể hỏng khi cập nhật; phân biệt bên gửi theo mép bong bóng (mép trái ≈ 13% chiều rộng màn hình = đối phương, mép phải ≈ chiều rộng màn hình − 5px = bạn); tiêu đề trò chuyện nhóm thường không lấy được vì thanh tiêu đề chỉ hiển thị emoji và số thành viên |
| X / Twitter tin nhắn riêng | ✅ Hỗ trợ đầy đủ từ đầu đến cuối | Phân tích content-desc của node Compose | Đã kiểm thử trên 12.25, giao diện tiếng Trung; chưa xác minh giao diện tiếng Anh |
| 飞书 / Lark | ✅ Dự phòng bằng OCR (đã xác minh trên thiết bị thật) | Đọc hình chữ nhật bong bóng bằng dịch vụ trợ năng + OCR tiếng Trung ngoại tuyến bằng ML Kit để nhận dạng nội dung chính | Nội dung chính tự vẽ không có trong cây trợ năng; từ 1.3, thực hiện OCR cho hình chữ nhật từng bong bóng; phân biệt tôi/đối phương theo trạng thái đã đọc |
| WhatsApp | 🧪 Trò chuyện 1v1 | Đọc node bằng dịch vụ trợ năng | Chỉ đọc trò chuyện 1v1, không đọc nhóm, không chụp màn hình; trả lời theo ngôn ngữ tin nhắn mới nhất của đối phương. Quy tắc đọc của [@smgonthebeat](https://github.com/smgonthebeat) (#73), kiểm chứng với bản ghi WhatsApp 2.26.38.73 |
| Telegram | ✅ Hỗ trợ đầy đủ từ đầu đến cuối | Đọc node bằng dịch vụ trợ năng | Đã kiểm thử trên 12.10.1 (versionCode 70382): mỗi dòng có "biệt danh / nội dung / dòng trạng thái", phân biệt người gửi theo động từ trạng thái (`已发送` = bạn, `已收到` = đối phương), nên giao diện không phải tiếng Trung hoặc tiếng Anh thì không phân biệt được trái/phải; trang chat nhận diện bằng ô nhập ở đáy (y ≥ 60% chiều cao màn hình), danh sách chat và trang chủ đề không hiện thẻ |
| WeChat | ✅ Hỗ trợ đầy đủ (OCR) | Chụp màn hình + OCR trên máy | Đã kiểm thử trên 8.0.78: WeChat không cung cấp cây trợ năng cho bên thứ ba (toàn bộ cây chỉ là một node rỗng `bounds="[0,0][0,0]"`), nên chỉ đọc được màn hình. Chụp màn hình → phân biệt trái/phải theo màu nền bong bóng (xanh lá = bạn, xám = đối phương; thẻ ảnh/tệp của bạn là màu xám, dùng ảnh đại diện bên phải chồng lên làm dự phòng) → OCR tiếng Trung bằng ML Kit. Chỉ kiểm thử giao diện tối; giao diện/skin khác chưa xác minh |
| Ứng dụng khác chưa hỗ trợ | ✅ Thủ công | OCR toàn màn hình bằng “Nhận diện ảnh chụp một lần” trong menu cửa sổ nổi | Không tự động, không phân biệt tôi/đối phương (mọi nội dung đều được coi là lời của đối phương và được ghi rõ trong khung phân tích); không hỗ trợ ứng dụng ẩn nội dung giao diện hoặc chặn chụp màn hình |
| macOS / Windows | ✅ Dự án gốc riêng | Xem từng kho | [macOS](https://github.com/jev-chat/jev-chat-jarvis-mac) · [Windows](https://github.com/jev-chat/jev-chat-windows) |
| Web | ⏳ Đang lên kế hoạch | — | Chưa có bản web |

Dự án này chỉ đọc nội dung chat trên thiết bị của chính bạn, nơi bạn có quyền xem và phiên bản hiện tại hỗ trợ; không đọc ứng dụng ẩn nội dung giao diện hoặc chặn chụp màn hình.

> **Rủi ro khi sử dụng:** Dùng trợ lý trong các ứng dụng bên thứ ba như QQ, TIM, 飞书, X hoặc WhatsApp có thể không phù hợp với thỏa thuận người dùng của ứng dụng đó, tài khoản có thể bị hạn chế hoặc khóa. Hãy tự cân nhắc trước khi sử dụng.

## Bắt đầu nhanh

**1. Build.** Nhánh này không phát hành APK; hãy build bản debug từ mã nguồn (Android 11 trở lên, chỉ ARM64 / `arm64-v8a`):

```bash
# cần JDK 17 hoặc 21 và Android SDK (compileSdk 35)
cd cn
JAVA_HOME=/usr/lib/jvm/java-21-openjdk bash gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

APK release của dự án gốc nằm ở [Releases](https://github.com/jev-chat/jev-chat-jarvis/releases) của kho gốc. Đó là một ứng dụng khác với tên gói khác (bản gốc `jev-assistant-v1.7-release.apk`), nên hai bản không ghi đè lên nhau và không thể nâng cấp tại chỗ.

**2. Nhập khóa.** Mở ứng dụng → Cài đặt → “API”, chia thành ba thẻ: API phân tích / API trả lời / API thị giác. Cách đơn giản nhất là chỉ điền [API Key của OpenRouter](https://openrouter.ai/) vào thẻ “API phân tích”; để trống hai thẻ còn lại để chúng tự động kế thừa khóa này và ứng dụng sẽ dùng được. Không dùng OpenRouter cũng được: thẻ “API phân tích” có sẵn cấu hình “DeepSeek chính thức”, chỉ cần một khóa DeepSeek là dùng được (DeepSeek không có mô hình phán đoán Jev, nên cấu hình này tự chuyển sang “chế độ chat OpenAI” và trả lời cùng bộ câu hỏi, xem bên dưới). Nếu muốn đổi mô hình trả lời (mặc định `deepseek/deepseek-chat-v3.1`; Gemini / OpenAI tại Trung Quốc sẽ bị giới hạn theo khu vực), hãy chọn một cấu hình có sẵn trong “API trả lời” (OpenRouter / DeepSeek chính thức / 通义兼容) hoặc tự nhập địa chỉ; mỗi thẻ có chức năng kiểm tra kết nối độc lập bằng một chạm.

**3. Bật quyền.** Làm theo hướng dẫn trên trang chủ để bật ba quyền:

- Trợ năng (đọc giao diện chat hiện được hỗ trợ; sau khi nâng cấp lên 1.3+, cần tắt rồi bật lại trợ năng để khả năng chụp màn hình có hiệu lực)
- Cửa sổ nổi / Hiển thị trên ứng dụng khác (hiển thị kết quả phân tích)
- Tự khởi động + không hạn chế tối ưu hóa pin (bắt buộc trên Xiaomi / HyperOS, nếu không tiến trình nền sẽ bị đóng băng và không thể đọc tin nhắn)

Người dùng đã cài gói debug phải gỡ cài đặt trước khi cài release (chữ ký khác nhau), và việc gỡ cài đặt sẽ xóa cả khóa lẫn thiết lập. Sau khi cài lại trên Xiaomi / HyperOS, quyền cửa sổ nổi sẽ bị đặt lại; sau khi cài, hãy bật lại theo hướng dẫn.

## Tính năng

### Phân tích và câu trả lời ứng viên

- Mô hình phân tích trả lời một lần với: ý định thật của đối phương, mức độ nguy hiểm (0–9), điều đối phương muốn, có nên trả lời ngay hay không, hành động tốt nhất. Khoảng 1 giây, kèm mức độ chắc chắn.
- Mô hình tạo sinh soạn 3 câu trả lời ứng viên bằng văn phong nói tự nhiên; mô hình phân tích xếp hạng theo mức “phù hợp nhất” và đưa ra tỷ lệ.
- Chạm một lần trong cửa sổ nổi để sao chép hoặc điền câu trả lời; thao tác điền dùng `ACTION_SET_TEXT`, nếu thất bại sẽ tự chuyển sang dán từ bảng nhớ tạm, **trong mọi trường hợp đều không gửi**.

### Cơ sở tri thức và liên hệ

Tại Cài đặt → Phân tích → “Cơ sở tri thức và liên hệ”.

- **Ghi chú**: tiêu đề / nội dung / thẻ / thường trực. Ghi chú thường trực luôn được đưa vào; các ghi chú khác được chọn theo độ liên quan BM25 (tiêu đề, thẻ và nội dung đều tham gia chấm điểm), tối đa 5 ghi chú. Hỗ trợ nhập bằng cách dán văn bản nhiều dòng, phân đoạn theo dòng trống và lấy dòng đầu mỗi đoạn làm tiêu đề.
- **Liên hệ**: tên / bí danh (mỗi dòng một bí danh) / quan hệ / ghi chú. Có hiệu lực khi tiêu đề cuộc trò chuyện khớp với tên hoặc bất kỳ bí danh nào; tự động bỏ qua số người ở cuối tên nhóm, khoảng trắng đầu/cuối và khác biệt chữ hoa chữ thường. Có thể nhấn giữ vào bong bóng cửa sổ nổi để lưu nhanh cuộc trò chuyện hiện tại làm liên hệ bằng một chạm.
- **Lịch sử**: “Ghi lại lịch sử trò chuyện (chỉ lưu trên máy)” mặc định tắt; khi bật, mỗi lần phân tích sẽ kèm N tin nhắn gần nhất (mặc định 30 trong cài đặt; bộ ngân sách nội bộ tối đa đưa 20 tin vào ngữ cảnh soạn) và tự động loại bỏ phần đã hiển thị trên màn hình.
- **Xóa**: cơ sở tri thức và lịch sử đều nằm trong thư mục riêng của ứng dụng; nút “Xóa cơ sở tri thức và lịch sử” trong cài đặt xóa toàn bộ chỉ bằng một lần nhấn, không ghi vào nhật ký, không đưa vào git. Xem [chính sách quyền riêng tư](../cn/PRIVACY.md) để biết các loại dữ liệu cụ thể, mục đích, bên nhận và cách lưu giữ.
- Phần đầu khung phân tích trong cửa sổ nổi hiển thị một dòng “Cơ sở tri thức N mục · Lịch sử M mục” để tiện xác nhận những gì đã được đưa vào.

### Thư viện chuyên gia

Tại Cài đặt → “Nhân vật và giọng điệu” → “Mở thư viện chuyên gia”.

- **Hai tầng:** thư viện của bạn (đổi tên, sửa, xoá, xuất) và danh mục chỉ đọc đóng gói trong APK (331 vị thuộc 22 lĩnh vực). Danh mục chỉ là mẫu: chỉ vào thư viện khi bạn bấm chọn.
- **“Dùng chuyên gia này” = thêm vào rồi áp dụng:** phần thân nhân vật được ghi vào đoạn văn bản nhân vật trong Cài đặt (vẫn là nguồn duy nhất) và ghi nhận một lần dùng (dữ liệu cho sắp xếp “dùng nhiều”). “Thêm vào thư viện” chỉ thêm, không đổi nhân vật hiện tại. Khi đã có trong thư viện, danh mục không hiển thị thêm bản trùng.
- **Chỉ phần thân vào prompt:** giọng điệu và quy tắc đều đến từ chủ đề / cách gọi / giọng điệu / tình huống / quy tắc / câu ví dụ trong phần thân; ảnh, mô tả, thẻ, phân loại và số lần dùng chỉ dùng để duyệt và sắp xếp.
- **Lưới và tìm kiếm:** lưới thẻ hai cột, ngăn phân loại, tìm theo tên / mô tả / thẻ / phần thân, ba kiểu sắp xếp (tổng hợp / dùng nhiều / mới nhất), 14 thẻ khởi đầu cùng tạo, nhân bản, nhập/xuất, xoá và khôi phục mẫu.
- **Ràng buộc chuyên gia (bản xám, mặc định tắt):** chuyên gia có thể chỉ định kỹ năng cần nạp và ứng dụng sẽ xuất hiện; khi bật chỉ nạp các kỹ năng được chỉ định, khi tắt đường lắp ghép giống hệt trước đây.

### API và mô hình

- Địa chỉ, khóa và mô hình của ba luồng phân tích / trả lời / thị giác có thể điền riêng.
- API phân tích bổ sung cấu hình tích hợp “博查 Jev”, ở vị trí thứ hai (OpenRouter / 博查 Jev / TypeSafe trực tiếp / Vercel / OpenCode Zen / Tùy chỉnh); khi chọn, ứng dụng tự điền địa chỉ dịch vụ `https://jev.bocha.cn` và mô hình `bocha-jev-v1` (giao thức giống TypeSafe), hiển thị địa chỉ chính thức trên trang và hỗ trợ sao chép bằng một chạm; hiện miễn phí trong thời gian giới hạn. Bản cài mới mặc định dùng OpenRouter; người dùng cũ đã cấu hình API phân tích không bị ảnh hưởng, provider và khóa đều không thay đổi.
- API phân tích có thêm cấu hình tích hợp “Vercel”: địa chỉ `https://ai-gateway.vercel.sh/typesafe`, mô hình `typesafe-ai/jev`, sử dụng khóa từ [Vercel AI Gateway](https://vercel.com/ai-gateway/models/jev). Giao thức giống kết nối trực tiếp TypeSafe (`POST /v1/systemone`).
- API phân tích có thêm cấu hình tích hợp “OpenCode Zen”: địa chỉ `https://opencode.ai/zen`, mô hình `jev-1.13` (đầu ra miễn phí, đầu vào $0.042/M, mỗi lần phân tích khoảng 1000 token đầu vào), sử dụng khóa từ [OpenCode Zen](https://opencode.ai/zen). Giao thức giống kết nối trực tiếp TypeSafe (`POST /v1/systemone`); nếu muốn dùng hoàn toàn miễn phí, có thể đổi thủ công thành `jev-1.13-free` (miễn phí trong thời gian giới hạn, chức năng bị hạn chế).
- API phân tích cũng có thể dùng DeepSeek: cấu hình có sẵn “DeepSeek chính thức” (địa chỉ `https://api.deepseek.com/v1`, mô hình `deepseek-chat`, dùng khóa DeepSeek). DeepSeek không cung cấp mô hình phán đoán Jev, nên khi chọn, giao thức phán đoán tự chuyển sang “chế độ chat OpenAI”: cùng bộ 7 câu hỏi được viết thành prompt cho mô hình chat và trả về đúng cấu trúc JSON đó — ý định, mức độ nguy hiểm, đối phương cần gì, có nên trả lời ngay, xếp hạng câu trả lời đều hoạt động như thường.
- API phân tích có thêm hai nút “giao thức Jev / chế độ chat OpenAI” quyết định cách giao tiếp của nhánh này. Giao thức Jev gửi câu hỏi cho mô hình phán đoán Jev (họ TypeSafe, câu trả lời đã hiệu chuẩn); chế độ chat gửi cho mô hình chat thường, xác suất và mức độ nguy hiểm do nó tự ước lượng, kém chính xác hơn Jev và mỗi lần phán đoán phải mang theo toàn bộ bộ câu hỏi (khoảng 2000–3000 token đầu vào, chậm và đắt hơn Jev). Cấu hình có sẵn tự chọn đúng giao thức (DeepSeek = chế độ chat, còn lại = giao thức Jev); địa chỉ tùy chỉnh có thể chọn. Nâng cấp từ bản cũ giữ nguyên đường đi.
- Có sẵn các cấu hình OpenRouter / 博查 Jev / TypeSafe trực tiếp / Vercel / OpenCode Zen / DeepSeek chính thức / 通义兼容; mỗi thẻ có thể kiểm tra kết nối bằng một chạm.
- Chỉ cần một khóa là có thể dùng: **khóa** của API trả lời và thị giác để trống sẽ tự động kế thừa theo chuỗi (thị giác → trả lời → phân tích); địa chỉ và mô hình không kế thừa — API trả lời để trống thì mặc định đi OpenRouter (khi phân tích dùng DeepSeek, phần trả lời hoặc cấu hình DeepSeek luôn, hoặc giữ mặc định OpenRouter và điền khóa OpenRouter).
- Khi nâng cấp từ phiên bản cũ, khóa cũ sẽ được chuyển sang cấu trúc ba thẻ mới đúng một lần.

### Thu thập và OCR

- Mỗi ứng dụng có một adapter; dịch vụ phân phối theo tên gói của ứng dụng đang ở tiền cảnh, adapter chỉ chịu trách nhiệm biến cửa sổ hiện tại thành “tiêu đề + danh sách tin nhắn”.
- Khi cây trợ năng không có nội dung chính, ứng dụng chat được hỗ trợ sẽ tự động chụp màn hình và dùng mô hình tiếng Trung ngoại tuyến của ML Kit để nhận diện; không tải ảnh lên và không cần dịch vụ Google.
- Việc chụp màn hình có giới hạn tần suất và cơ chế lùi thời gian chờ khi thất bại, không chụp liên tục mỗi giây; khi nhận diện sẽ tránh cửa sổ nổi của chính ứng dụng.
- Với ứng dụng chưa được hỗ trợ, có thể kích hoạt thủ công “Nhận diện ảnh chụp một lần” từ menu cửa sổ nổi.

## Câu hỏi thường gặp

<details>
<summary><b>Ứng dụng có tự gửi tin nhắn thay tôi không?</b></summary>

Không. Ứng dụng chỉ điền câu trả lời đã chọn vào ô nhập; bạn luôn tự bấm nút gửi. Ứng dụng không bao giờ can thiệp vào việc chuyển tiền, lì xì hoặc thu tiền.

</details>

<details>
<summary><b>Có cần root hay Xposed không? Tài khoản có bị khóa không?</b></summary>

Đường mặc định không cần root và không phải cài bất kỳ module nào: ứng dụng chỉ đọc nội dung giao diện do dịch vụ trợ năng của hệ thống cung cấp, giống như một phần mềm đọc màn hình. Lớp tăng cường tùy chọn qua LSPosed / Vector mới cần framework root — tắt theo mặc định, bật riêng cho từng ứng dụng, và có rủi ro tài khoản (xem [hướng dẫn tính năng](../cn/docs/feature-guide.md)); khi không bật, hành vi giống hệt như không có tiêm mã.

</details>

<details>
<summary><b>Lịch sử trò chuyện của tôi có được tải lên không?</b></summary>

Khi kích hoạt phân tích, nội dung chat hiện tại cùng ghi chú liên hệ mà bạn đã bật, nội dung cơ sở tri thức được truy xuất và lịch sử trò chuyện sẽ được gửi tới API mô hình mà bạn cấu hình trong cài đặt. Người duy trì nhánh này không vận hành máy chủ trung gian và không nhận được nội dung này; ảnh chụp màn hình được OCR trên máy và không tải lên. Lịch sử mặc định tắt; khi bật, lịch sử chỉ được lưu trong thư mục riêng của ứng dụng trên máy. Nhà cung cấp mô hình bên thứ ba có thể xử lý nội dung yêu cầu theo chính sách của họ; vui lòng xem [chính sách quyền riêng tư](../cn/PRIVACY.md) và chính sách của nhà cung cấp đã chọn trước khi sử dụng.

</details>

<details>
<summary><b>Bong bóng nổi biến mất hoặc không đọc được tin nhắn thì làm sao?</b></summary>

Khả năng cao là ROM của hãng Trung Quốc đã đóng băng tiến trình nền. Trước tiên hãy kiểm tra rằng cả bốn quyền trợ năng, cửa sổ nổi, tự khởi động và không hạn chế tối ưu hóa pin đều đang bật, đặc biệt là hai quyền cuối trên Xiaomi / HyperOS. Quyền cửa sổ nổi sẽ bị đặt lại sau khi cài lại, vui lòng bật lại theo hướng dẫn trên trang chủ. Chạm bất kỳ đâu trong giao diện chat thường sẽ giúp ứng dụng tự khôi phục.

</details>

<details>
<summary><b>Không đọc được nội dung chính trong 飞书? Các ứng dụng khác dùng được không?</b></summary>

Nội dung chính của tin nhắn trong 飞书 được tự vẽ nên không có chữ trong cây trợ năng; từ phiên bản 1.3, ứng dụng chuyển sang OCR ngoại tuyến cho hình chữ nhật của từng bong bóng. Với các ứng dụng khác chưa được hỗ trợ, có thể nhấn “Nhận diện ảnh chụp một lần” trong menu cửa sổ nổi; sau khi OCR toàn màn hình, ứng dụng có thể phân tích theo cách tương tự, nhưng không phân biệt tin của tôi và của đối phương.

</details>

<details>
<summary><b>Có tốn tiền không?</b></summary>

Phần mềm miễn phí và mã nguồn mở. Việc gọi mô hình sử dụng API Key của bạn và được tính phí theo mức sử dụng tại nhà cung cấp tương ứng; dự án không xử lý bất kỳ khoản phí nào.

</details>

<details>
<summary><b>Nâng cấp xong không phản hồi thì làm sao?</b></summary>

Hãy tắt rồi bật lại công tắc trợ năng trong cài đặt hệ thống. Từ phiên bản 1.3, tính năng chụp màn hình mới được thêm và dịch vụ phải được liên kết lại để có hiệu lực.

</details>

## Cách hoạt động

![Quy trình chính của trợ lý đồng hành hội thoại Jev Android: đọc và OCR trên máy, gửi chữ tới API mô hình do người dùng cấu hình, hiển thị câu trả lời ứng viên và để người dùng quyết định có gửi hay không](assets/android-core-flow-illustrations/01-chat-copilot-flow.png)

Hình minh họa ranh giới dữ liệu: đọc giao diện chat và OCR được thực hiện trên máy; khi kích hoạt phân tích, chữ và thông tin nền đang bật được gửi tới nhà cung cấp mô hình mà bạn cấu hình; câu trả lời ứng viên được bạn xác nhận và ứng dụng không tự gửi. Xem thêm [chính sách quyền riêng tư](../cn/PRIVACY.md).

- **Thu thập**: mỗi ứng dụng có một adapter; dịch vụ phân phối theo tên gói của ứng dụng đang ở tiền cảnh. Adapter chỉ chịu trách nhiệm biến cửa sổ hiện tại thành “tiêu đề + danh sách tin nhắn (ai nói, nói gì)”, các thành phần phía sau đều dùng chung; khi cây trợ năng không có nội dung chính thì dùng chụp màn hình + OCR ngoại tuyến làm phương án dự phòng (có giới hạn tần suất, lùi thời gian chờ khi thất bại, không chụp liên tục mỗi giây).
- **Phân tích**: [Jev](https://docs.typesafe.ai/) chỉ trả lời lựa chọn / chấm điểm / đúng-sai, gửi tất cả câu hỏi trong một yêu cầu và trả về sau khoảng 1 giây; khi có dữ liệu khớp trong cơ sở tri thức, state sẽ chứa `background` (quan hệ + ghi chú liên hệ + ghi chú được truy xuất) và `history` (lịch sử tin nhắn).
- **Trả lời**: mô hình sinh soạn 3 câu trả lời ứng viên, Jev xếp hạng; lời nhắc yêu cầu câu trả lời phải nhất quán với cơ sở tri thức và không bịa đặt sự thật không có trong cơ sở tri thức.
- **Điền lại**: dùng `ACTION_SET_TEXT`; nếu thất bại thì dùng bảng nhớ tạm + `ACTION_PASTE`, không gửi.

<details>
<summary><b>Tích hợp một ứng dụng chat mới</b></summary>

1. Trong `capture/ChatAppAdapter.kt`, triển khai `ChatAppAdapter`: `pkg` là tên gói; `extract(root, res)` lấy tiêu đề và danh sách tin nhắn từ cây trợ năng (`Msg(side, text)`, trong đó `side` là `me` / `other`); trả về `null` nếu không ở trong cửa sổ chat.
2. Thêm một dòng vào `adapters` trong `capture/ChatCaptureService.kt`.
3. Không cần thay đổi phần phân tích, câu trả lời ứng viên, cửa sổ nổi hoặc chức năng điền lại.

Trước tiên hãy dùng `adb shell uiautomator dump` để xem ứng dụng đích cung cấp những gì; hiện có sáu adapter chuyên biệt (QQ, TIM, X, 飞书, WhatsApp, Telegram), ngoài ra còn có lối vào OCR thủ công cho các ứng dụng chưa được hỗ trợ:

| Ứng dụng | Tình trạng cây | Adapter thực hiện |
|---|---|---|
| QQ | Node được dịch vụ trợ năng cung cấp, có id | Nội dung `id/mjn`, tiêu đề `id/371`, xác định ai nói dựa vào bên bong bóng tiếp giáp với ảnh đại diện |
| X | Compose, không có id, text trống | Phân tích content-desc `发件人：正文。时间。Read`; người gửi là 「你」 tức là phía của tôi |
| 飞书 | Nội dung chính tự vẽ, cây không có chữ | Lấy hình chữ nhật bubble_content_container và trạng thái đã đọc từ cây, OCR nội dung chính cho từng hình chữ nhật |

Adapter trả về `null` nghĩa là không ở trong cửa sổ chat; trả về danh sách tin nhắn rỗng nghĩa là đang ở trong cửa sổ chat nhưng cây không có nội dung chính — chỉ trường hợp sau mới kích hoạt phương án dự phòng OCR.

Trong toàn bộ luồng của QQ và X chỉ có một Activity, nên để xác định có đang ở cửa sổ chat hay không phải dựa vào việc cây có đúng các nút cần thiết hay không (ví dụ ô nhập), chứ không phải tên Activity.

</details>

<details>
<summary><b>Build và cấu trúc thư mục</b></summary>

JDK 17 + Android SDK (platform 35 / build-tools 35).

```bash
cd cn
./gradlew assembleDebug      # app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleRelease    # Cần thuộc tính chữ ký properties bên ngoài kho, đường dẫn do JEV_KEYSTORE_PROPS chỉ định
```

- `cn/app/` — ứng dụng Android (Kotlin, View cổ điển)
  - `capture/` thu thập bằng trợ năng: `ChatAppAdapter.kt` chứa adapter cho từng ứng dụng, `ChatCaptureService.kt` là dịch vụ phân phối, giữ tiến trình ở tiền cảnh, `ocr/` chụp màn hình và nhận diện ngoại tuyến
  - `jev/` máy khách và bộ câu hỏi Jev · `overlay/` cửa sổ nổi · `core/` cấu hình và mô hình dữ liệu (gồm `core/kb/` lưu trữ cơ sở tri thức và xây dựng ngữ cảnh)
  - `KnowledgeActivity` trang quản lý cơ sở tri thức (ghi chú / liên hệ)
- `cn/tools/jev/` — bộ câu hỏi và bộ công cụ hiệu chuẩn cho Jev (Python)
- `cn/docs/` — tài liệu thiết kế và nghiệm thu
- `cn/apk/` — gói release đã ký

</details>

## Hạn chế đã biết

- **Đóng băng tiến trình nền trên ROM của hãng Trung Quốc**: Xiaomi / HyperOS có thể giết tiến trình nền; ngay cả khi đã cấu hình giữ tiến trình ở tiền cảnh, tự khởi động và không hạn chế tối ưu hóa pin, ứng dụng vẫn có thể bị giết, bong bóng sẽ tạm thời biến mất và tự phục hồi khi tương tác lại trong giao diện chat.
- **Nội dung chính của 飞书 phụ thuộc OCR**: nội dung tin nhắn trong 飞书 là thành phần giao diện tự vẽ và cây trợ năng chỉ có hình chữ nhật bong bóng; từ phiên bản 1.3, ứng dụng dùng OCR ngoại tuyến cho từng hình chữ nhật; phía tôi/đối phương được phân biệt theo trạng thái đã đọc; nếu phân biệt ngược, hãy dùng “Lưu làm liên hệ” và ghi rõ trong ghi chú, hoặc tắt tự động phân tích để dùng thủ công.
- **X chỉ được kiểm chứng với giao diện tiếng Trung**: dấu phân cách `：`, cụm `上午 / 下午` và `Read` là kết quả thử trên giao diện tiếng Trung; giao diện tiếng Anh mới chỉ có phương án dự phòng và chưa kiểm chứng.
- **Trò chuyện nhóm**: phân tích theo mô hình một-một, nên “đối phương” và thiết lập quan hệ có thể không chính xác trong nhóm.
- **Tiếng Trung**: ngôn ngữ huấn luyện chính của Jev là tiếng Anh; câu hỏi dùng tiếng Anh, còn nội dung chat giữ nguyên tiếng Trung; nên thực hiện một loạt gán nhãn và hiệu chuẩn bằng các hội thoại thật của bạn (xem `cn/tools/jev/`).
- **Truy xuất cơ sở tri thức dùng độ liên quan BM25** (tiêu đề, thẻ và nội dung đều tham gia chấm điểm), không dùng truy xuất ngữ nghĩa (vector); viết cụ thể, từ khóa khớp thì ghi chú dễ được chọn. Lịch sử được loại trùng theo “người nói + nguyên văn”, cùng một người lặp lại cùng một câu sẽ chỉ được ghi một lần.
- **OCR phụ thuộc vào quyền chụp màn hình của hệ thống**: dịch vụ trợ năng phải được hệ thống cho phép chụp màn hình; Xiaomi / HyperOS có thể từ chối (khung phân tích sẽ hiện lý do thất bại); không thể chụp cửa sổ được bảo vệ (`FLAG_SECURE`).
- **OCR chỉ nhận diện được phần đang hiện trên màn hình**: không thể đọc phần bị cắt của tin nhắn dài; có thể có chữ sai.
- **Kích thước gói tăng**: mô hình tiếng Trung ngoại tuyến của ML Kit làm APK tăng từ khoảng 12 MB lên khoảng 27 MB và chỉ build cho arm64-v8a.
- **Không hỗ trợ ứng dụng ẩn nội dung giao diện hoặc chặn chụp màn hình**: trong các ứng dụng này, phiên bản hiện tại không thu thập, không chụp màn hình và không điền nội dung.

## Bản quyền và giấy phép

Bản gốc: Copyright © 2026 Finderchangchang và những người đóng góp cho jev-chat. Mã nguồn được phát hành theo giấy phép mã nguồn mở [MIT](../LICENSE), xem thêm [NOTICE](../NOTICE). **Kho này là một nhánh phát triển tiếp của dự án đó** (dùng cục bộ, tên gói `com.jev.probe`, phiên bản 2.0 đang phát triển); tác giả gốc không tham gia và không chứng thực cho bất kỳ thay đổi nào trong nhánh này.

- **Có thể sử dụng thương mại**: cả cá nhân và công ty đều có thể sử dụng, chỉnh sửa, phân phối lại hoặc tích hợp vào sản phẩm của mình mà không cần trả phí hoặc xin phép trước.
- **Bắt buộc ghi nguồn**: khi phân phối hoặc sử dụng thương mại, phải giữ lại LICENSE và NOTICE, đồng thời ghi nguồn trong trang “Giới thiệu”, tài liệu hoặc trang phát hành của sản phẩm. Cách ghi được khuyến nghị: `Dựa trên Jev 聊天助手（https://github.com/jev-chat/jev-chat-jarvis） để phát triển tiếp`.
- Không dùng tên “Jev 聊天助手”, “jev-chat” hoặc tên miền chatjevs.com để gợi ý rằng sản phẩm do tác giả gốc phát hành hoặc chứng thực.

**Quyền riêng tư và miễn trừ trách nhiệm**: khi kích hoạt phân tích, nội dung trò chuyện và thông tin nền đang bật sẽ được gửi tới nhà cung cấp mô hình bên thứ ba do bạn tự cấu hình; ảnh chụp màn hình chỉ được OCR trên máy. Vui lòng đọc [chính sách quyền riêng tư](../cn/PRIVACY.md) cùng chính sách của nhà cung cấp đã chọn và tuân thủ điều khoản của QQ, X, 飞书, WhatsApp và các phần mềm khác cùng pháp luật và quy định địa phương. Người duy trì nhánh này không chịu trách nhiệm về hành vi xử lý dữ liệu hoặc hậu quả sử dụng của nhà cung cấp bên thứ ba.
