package com.jev.probe.bridge

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import com.jev.probe.core.Trace

/**
 * 跨进程桥的主通道。authority = [BridgeContract.AUTHORITY]，exported。
 *
 * 这里**故意不加** provider 级 permission：调用方是跑在目标 App 进程里的注入
 * 代码，Binder 报的是目标 App 的 uid，任何自家签名级权限都会把它挡在门外。
 * 门禁改成 UID 白名单，见 [BridgeAuth]；放行之外的 uid 直接抛
 * SecurityException 并记一行 Trace。
 *
 * 只支持 `call()`：query/insert/update/delete 全部返回 null，因为这个 Provider
 * 不代表任何一张表，它是一条命令通道。
 */
class BridgeProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        Trace.log("bridge provider created")
        return true
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val ctx = context ?: return null
        return BridgeDispatch.handle(ctx, Binder.getCallingUid(), method, arg, extras)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
