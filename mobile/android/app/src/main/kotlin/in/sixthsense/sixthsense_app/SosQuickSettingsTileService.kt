package `in`.sixthsense.sixthsense_app

import android.service.quicksettings.TileService

class SosQuickSettingsTileService : TileService() {
    override fun onClick() {
        super.onClick()
        LocalSosNotifier.show(this)
    }
}
