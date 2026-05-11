import SwiftUI
import CoreBluetooth

// MARK: - Camera Settings

enum FrameSize: Int, CaseIterable, Identifiable {
    case qqvga = 1    // 160x120
    case qvga = 5     // 320x240
    case cif = 6      // 400x296
    case vga = 8      // 640x480
    case svga = 9     // 800x600
    case xga = 10     // 1024x768
    case sxga = 12    // 1280x1024
    case uxga = 13    // 1600x1200
    case qxga = 17    // 2048x1536

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .qqvga: return "QQVGA (160×120)"
        case .qvga:  return "QVGA (320×240)"
        case .cif:   return "CIF (400×296)"
        case .vga:   return "VGA (640×480)"
        case .svga:  return "SVGA (800×600)"
        case .xga:   return "XGA (1024×768)"
        case .sxga:  return "SXGA (1280×1024)"
        case .uxga:  return "UXGA (1600×1200)"
        case .qxga:  return "QXGA (2048×1536)"
        }
    }
}

// MARK: - BLE UUIDs (must match ESP32)

let ESP32_SERVICE_UUID     = CBUUID(string: "e5320ca0-0001-0001-0001-000000000001")
let ESP32_COMMAND_UUID     = CBUUID(string: "e5320ca0-0001-0001-0001-000000000002")
let ESP32_PHOTO_INFO_UUID  = CBUUID(string: "e5320ca0-0001-0001-0001-000000000003")
let ESP32_PHOTO_DATA_UUID  = CBUUID(string: "e5320ca0-0001-0001-0001-000000000004")
let ESP32_STATUS_UUID      = CBUUID(string: "e5320ca0-0001-0001-0001-000000000005")

// MARK: - BLE Camera Manager

class BLECamera: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?

    private var commandChar: CBCharacteristic?
    private var photoInfoChar: CBCharacteristic?
    private var photoDataChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?

    @Published var bleState: String = "Ініціалізація..."
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var rssi: Int = 0

    @Published var capturedImage: UIImage?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false

    @Published var ledIntensity: Int = 50
    @Published var psramFree: Int = 0
    @Published var photoSize: Int = 0
    @Published var uptime: Int = 0
    @Published var sleepHours: Int = 24
    @Published var awakeMinutes: Int = 5
    @Published var currentFrameSize: Int = 8

    @AppStorage("flashBrightness") var flashBrightness: Double = 50

    var photoData = Data()
    var expectedPhotoSize: UInt32 = 0
    private var awaitingPhoto = false
    private var chunksReceived = 0

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public Actions

    func scan() {
        guard centralManager.state == .poweredOn else {
            bleState = "Bluetooth вимкнений"
            return
        }
        isScanning = true
        bleState = "Пошук ESP32-CAM..."
        centralManager.scanForPeripherals(withServices: [ESP32_SERVICE_UUID], options: nil)

        // Stop scan after 15 sec
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.centralManager.stopScan()
            self.isScanning = false
            if !self.isConnected {
                self.bleState = "ESP32-CAM не знайдено"
            }
        }
    }

    func disconnect() {
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }

    func capturePhoto() {
        sendCommand("capture")
        isLoading = true
        isDownloading = false
        downloadProgress = 0
        errorMessage = nil
        photoData = Data()
        chunksReceived = 0
        awaitingPhoto = true
    }

    func fetchSavedPhoto() {
        sendCommand("saved")
        isLoading = true
        isDownloading = false
        downloadProgress = 0
        errorMessage = nil
        photoData = Data()
        chunksReceived = 0
        awaitingPhoto = true
    }

    func setFlash(_ value: Int) {
        sendCommand("flash:\(value)")
        flashBrightness = Double(value)
    }

    func setFrameSize(_ size: FrameSize) {
        sendCommand("framesize:\(size.rawValue)")
    }

    func setSleepHours(_ hours: Int) {
        sendCommand("sleep:\(hours)")
    }

    func setAwakeMinutes(_ minutes: Int) {
        sendCommand("awake:\(minutes)")
    }

    func cancelDownload() {
        awaitingPhoto = false
        isLoading = false
        isDownloading = false
        errorMessage = "Скасовано"
    }

    // MARK: - Private

    private func sendCommand(_ cmd: String) {
        guard let char = commandChar, let p = peripheral else {
            errorMessage = "Не підключено до ESP32"
            return
        }
        let data = cmd.data(using: .utf8)!
        p.writeValue(data, for: char, type: .withResponse)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bleState = "Bluetooth готовий"
            scan()
        case .poweredOff:
            bleState = "Увімкни Bluetooth"
            isConnected = false
        case .unauthorized:
            bleState = "Дозволь Bluetooth в налаштуваннях"
        default:
            bleState = "Bluetooth недоступний"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.rssi = RSSI.intValue
        self.peripheral = peripheral
        peripheral.delegate = self
        centralManager.stopScan()
        isScanning = false
        bleState = "Підключення..."
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        bleState = "Підключено"
        peripheral.discoverServices([ESP32_SERVICE_UUID])

        // Read RSSI periodically
        peripheral.readRSSI()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        bleState = "Відключено"
        commandChar = nil
        photoInfoChar = nil
        photoDataChar = nil
        statusChar = nil

        // Auto reconnect after 2 sec
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scan()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        bleState = "Помилка підключення"
        isConnected = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scan()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == ESP32_SERVICE_UUID }) else { return }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        for char in chars {
            switch char.uuid {
            case ESP32_COMMAND_UUID:
                commandChar = char
            case ESP32_PHOTO_INFO_UUID:
                photoInfoChar = char
                peripheral.setNotifyValue(true, for: char)
            case ESP32_PHOTO_DATA_UUID:
                photoDataChar = char
                peripheral.setNotifyValue(true, for: char)
            case ESP32_STATUS_UUID:
                statusChar = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }

        bleState = "Готово"
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case ESP32_PHOTO_INFO_UUID:
            // Received photo size (4 bytes uint32)
            guard data.count >= 4 else { return }
            expectedPhotoSize = data.withUnsafeBytes { $0.load(as: UInt32.self) }

            if expectedPhotoSize == 0 {
                isLoading = false
                isDownloading = false
                errorMessage = "Камера не зробила фото"
                awaitingPhoto = false
                return
            }

            photoData = Data()
            isDownloading = true
            // Tell ESP32 to start sending
            sendCommand("send")

        case ESP32_PHOTO_DATA_UUID:
            guard awaitingPhoto else { return }

            if data.isEmpty {
                // Empty = transfer complete
                finishPhotoTransfer()
                return
            }

            photoData.append(data)
            chunksReceived += 1

            if expectedPhotoSize > 0 {
                downloadProgress = Double(photoData.count) / Double(expectedPhotoSize)
            }

            // Flow control: request next batch every 10 chunks
            if chunksReceived % 10 == 0 {
                sendCommand("next")
            }

        case ESP32_STATUS_UUID:
            // Parse JSON status
            if let str = String(data: data, encoding: .utf8),
               let json = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] {
                ledIntensity = json["led"] as? Int ?? 0
                psramFree = json["psram_free"] as? Int ?? 0
                photoSize = json["photo_size"] as? Int ?? 0
                uptime = json["uptime"] as? Int ?? 0
                sleepHours = json["sleep_h"] as? Int ?? 24
                awakeMinutes = json["awake_m"] as? Int ?? 5
                currentFrameSize = json["framesize"] as? Int ?? 8
            }

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssi = RSSI.intValue

        // Read again in 5 seconds
        if isConnected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.peripheral?.readRSSI()
            }
        }
    }

    // MARK: - Photo Assembly

    private func finishPhotoTransfer() {
        awaitingPhoto = false
        isDownloading = false
        downloadProgress = 1.0

        guard let image = UIImage(data: photoData) else {
            errorMessage = "Не вдалося розпізнати фото (\(photoData.count) байт)"
            isLoading = false
            return
        }

        capturedImage = image
        isLoading = false
        errorMessage = nil
    }
}

// MARK: - Status Banner

struct StatusBanner: View {
    let bleState: String
    let isConnected: Bool
    let rssi: Int
    let isScanning: Bool
    let onScan: () -> Void

    var rssiDescription: String {
        switch rssi {
        case -50...0: return "Відмінний"
        case -60...(-51): return "Добрий"
        case -70...(-61): return "Нормальний"
        case -80...(-71): return "Слабкий"
        default: return "Дуже слабкий"
        }
    }

    var rssiColor: Color {
        switch rssi {
        case -50...0: return .green
        case -60...(-51): return .green
        case -70...(-61): return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundColor(isConnected ? rssiColor : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(bleState)
                    .font(.caption)
                    .fontWeight(.medium)
                if isConnected {
                    Text("BLE \(rssiDescription) (\(rssi) dBm)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                onScan()
            } label: {
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .disabled(isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isConnected ? Color(.systemGray6) : Color.red.opacity(0.1))
        )
        .padding(.horizontal)
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var camera = BLECamera()
    @State private var showShareSheet = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // BLE Status
                StatusBanner(
                    bleState: camera.bleState,
                    isConnected: camera.isConnected,
                    rssi: camera.rssi,
                    isScanning: camera.isScanning
                ) {
                    camera.scan()
                }

                // Progress bar
                if camera.isDownloading {
                    VStack(spacing: 4) {
                        ProgressView(value: camera.downloadProgress)
                            .progressViewStyle(.linear)
                            .tint(camera.downloadProgress < 1.0 ? .blue : .green)
                        HStack {
                            Text("\(Int(camera.downloadProgress * 100))%")
                            Spacer()
                            Text("\(camera.photoData.count) / \(camera.expectedPhotoSize) байт")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }

                // Photo preview
                if let image = camera.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                        .shadow(radius: 4)
                        .padding(.horizontal)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                            .aspectRatio(4/3, contentMode: .fit)
                            .padding(.horizontal)

                        VStack(spacing: 8) {
                            Image(systemName: "camera")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(camera.isConnected ? "Натисни кнопку для фото" : "Підключись до ESP32-CAM")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Error
                if let error = camera.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                // Buttons
                HStack(spacing: 12) {
                    if camera.isDownloading {
                        Button {
                            camera.cancelDownload()
                        } label: {
                            Label("Скасувати", systemImage: "xmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                    } else {
                        Button {
                            camera.capturePhoto()
                        } label: {
                            Label("Фото", systemImage: "camera.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(camera.isConnected ? Color.blue : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                        .disabled(!camera.isConnected || camera.isLoading)

                        Button {
                            camera.fetchSavedPhoto()
                        } label: {
                            Label("Збережене", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(camera.isConnected ? Color.orange : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                        .disabled(!camera.isConnected || camera.isLoading)
                    }

                    if camera.capturedImage != nil {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.headline)
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("ESP32-CAM BLE")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let image = camera.capturedImage {
                    ShareSheet(items: [image])
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(camera: camera)
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var camera: BLECamera
    @Environment(\.dismiss) private var dismiss
    @State private var flashValue: Double = 50
    @State private var sleepValue: Double = 24
    @State private var awakeValue: Double = 5
    @State private var selectedFrameSize: FrameSize = .vga

    var body: some View {
        NavigationStack {
            Form {
                Section("Роздільність") {
                    Picker("Розмір кадру", selection: $selectedFrameSize) {
                        ForEach(FrameSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .onChange(of: selectedFrameSize) { _, newValue in
                        camera.setFrameSize(newValue)
                    }
                }

                Section("Вспишка (LED)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "light.min")
                            Slider(value: $flashValue, in: 0...255, step: 1)
                            Image(systemName: "light.max")
                        }
                        Text("Яскравість: \(Int(flashValue)) / 255 (\(Int(flashValue / 255 * 100))%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Застосувати") {
                        camera.setFlash(Int(flashValue))
                    }
                    .disabled(!camera.isConnected)
                }

                Section("Deep Sleep (інтервал)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "moon.zzz")
                            Slider(value: $sleepValue, in: 1...168, step: 1)
                        }
                        Text(sleepLabel(Int(sleepValue)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Застосувати") {
                        camera.setSleepHours(Int(sleepValue))
                    }
                    .disabled(!camera.isConnected)
                }

                Section("Час очікування (awake)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "clock")
                            Slider(value: $awakeValue, in: 1...60, step: 1)
                        }
                        Text("\(Int(awakeValue)) хв — скільки чекає iPhone перед сном")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Застосувати") {
                        camera.setAwakeMinutes(Int(awakeValue))
                    }
                    .disabled(!camera.isConnected)
                }

                Section("Інформація") {
                    LabeledContent("BLE RSSI", value: "\(camera.rssi) dBm")
                    LabeledContent("PSRAM вільно", value: "\(camera.psramFree / 1024) KB")
                    LabeledContent("Останнє фото", value: "\(camera.photoSize) байт")
                    LabeledContent("Час роботи", value: formatUptime(camera.uptime))
                }

                if let error = camera.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Налаштування")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear {
                flashValue = camera.flashBrightness
                sleepValue = Double(camera.sleepHours)
                awakeValue = Double(camera.awakeMinutes)
                selectedFrameSize = FrameSize(rawValue: camera.currentFrameSize) ?? .vga
            }
        }
    }

    private func sleepLabel(_ hours: Int) -> String {
        if hours < 24 { return "\(hours) год — прокидається кожні \(hours) год" }
        let days = hours / 24
        let h = hours % 24
        if h == 0 { return "\(days) дн — прокидається кожні \(days) дн" }
        return "\(days) дн \(h) год"
    }

    private func formatUptime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)г \(m)хв" }
        if m > 0 { return "\(m)хв \(s)с" }
        return "\(s)с"
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
