"""Resolve the CV1 wire UUIDs from the pinned Omi source for both native hosts."""
import re

MODEL_FIELDS = {
    'audioService': 'omiServiceUuid',
    'audio': 'audioDataStreamCharacteristicUuid',
    'codec': 'audioCodecCharacteristicUuid',
    'buttonService': 'buttonServiceUuid',
    'button': 'buttonTriggerCharacteristicUuid',
    'batteryService': 'batteryServiceUuid',
    'battery': 'batteryLevelCharacteristicUuid',
    'storageService': 'storageDataStreamServiceUuid',
    'storageCommand': 'storageDataStreamCharacteristicUuid',
    'storageStatus': 'storageReadControlCharacteristicUuid',
    'deviceInfo': 'deviceInformationServiceUuid',
    'firmware': 'firmwareRevisionCharacteristicUuid',
    'hardware': 'hardwareRevisionCharacteristicUuid',
    'model': 'modelNumberCharacteristicUuid',
    'manufacturer': 'manufacturerNameCharacteristicUuid',
}
SETTINGS_FIELDS = {
    'featuresService': 'featuresServiceUuid',
    'features': 'featuresCharacteristicUuid',
    'settings': 'settingsServiceUuid',
    'led': 'settingsDimRatioCharacteristicUuid',
    'gain': 'settingsMicGainCharacteristicUuid',
    'charging': 'settingsChargingStatusCharacteristicUuid',
}


def cv1_uuids(app):
    devices = app / 'lib/services/devices'
    values = {}
    for path, fields in (('models.dart', MODEL_FIELDS), ('connectors/omi_connection.dart', SETTINGS_FIELDS)):
        source = (devices / path).read_text()
        for name, symbol in fields.items():
            value, = re.findall(
                rf"""\bconst String {symbol} = ['"]([a-f0-9-]{{36}})['"];""", source
            )
            values[name] = value
    return values


def cv1_feature_masks(app):
    source = (app / 'lib/services/devices.dart').read_text()
    masks = {}
    for native, dart in (('ledMask', 'ledDimming'), ('gainMask', 'micGain')):
        bit, = re.findall(rf'\bstatic const int {dart} = 1 << ([0-9]+);', source)
        masks[native] = 1 << int(bit)
    return masks
