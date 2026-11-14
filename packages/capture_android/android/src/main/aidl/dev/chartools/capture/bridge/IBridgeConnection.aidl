// 跨进程桥备用通道（AIDL Service）的接口。
//
// REF 仓库里 IBridgeConnection.aidl 的 blob 在 sparse clone 中缺失（与
// xposed_init 同类的缺失，见 root-module-design.md §5.3），本文件按调用点
// 契约重建：BridgeConnectionService.kt 的 Stub 匿名实现（call(method, arg,
// extras) 三参皆可空）与 BridgeTransport.kt:357 的
// `IBridgeConnection.Stub.asInterface(binder)`（M1 移植）。
// 全部参数与返回值声明 @nullable，使 Kotlin 侧 override 的 `String?` /
// `Bundle?` 签名成立。
package dev.chartools.capture.bridge;

interface IBridgeConnection {
    @nullable Bundle call(in @nullable String method, in @nullable String arg, in @nullable Bundle extras);
}
