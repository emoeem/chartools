package com.jev.probe.bridge;

import android.os.Bundle;

/**
 * 备用通道：Provider 取不到时显式绑定的那条 Service。
 *
 * 只有三个参数、一个 Bundle 返回，和 `ContentProvider.call` 完全同形 —— 两条
 * 通道共用 BridgeDispatch，所以「换通道」不会换语义（yanwai 的教训：已发出的
 * 操作不换通道重放，是因为通道失败发生在派发**之前**才安全）。
 */
interface IBridgeConnection {
    Bundle call(String method, String arg, in Bundle extras);
}
