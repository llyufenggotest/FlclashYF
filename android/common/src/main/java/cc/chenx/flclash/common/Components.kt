package cc.chenx.flclash.common

import android.content.ComponentName

object Components {
    const val PACKAGE_NAME = "cc.llyufeng.flclash.dev"
    private const val INTERNAL_PACKAGE_NAME = "cc.chenx.flclash"

    val mainActivity =
        ComponentName(GlobalState.packageName, "${INTERNAL_PACKAGE_NAME}.MainActivity")

    val quickActionActivity =
        ComponentName(GlobalState.packageName, "${INTERNAL_PACKAGE_NAME}.QuickActionActivity")

    val serviceBroadcastReceiver =
        ComponentName(GlobalState.packageName, "${INTERNAL_PACKAGE_NAME}.ServiceBroadcastReceiver")
}
