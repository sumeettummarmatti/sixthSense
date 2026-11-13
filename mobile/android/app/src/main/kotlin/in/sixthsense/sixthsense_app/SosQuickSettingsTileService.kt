package `in`.sixthsense.sixthsense_app

import android.service.quicksettings.TileService

class SosQuickSettingsTileService : TileService() {
    override fun onClick() {
        super.onClick()
        // During a journey the tile starts the same silent countdown as the volume buttons.
        SosGuard.current?.trigger(TriggerSource.BUTTON, "tile") ?: LocalSosNotifier.show(this)
    }
}
