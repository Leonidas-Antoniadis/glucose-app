import SwiftUI
import GlucoseCore
import LibreProtocol

/// Everything the sensor sends, byte by byte: Bluetooth packets and NFC reads, raw and decoded.
struct RawDataView: View {
    @Environment(AppModel.self) private var model
    @Environment(SensorConnection.self) private var sensor

    var body: some View {
        List {
            Section {
                Text("Every minute the sensor sends 46 bytes over Bluetooth. The first 2 are plain and seed the decryption; the other 44 are encrypted with a key derived from the sensor's ID. Decrypted, they hold 10 readings, the sensor's age and a checksum. Tap a packet to see each byte.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.isDemo {
                    Label("Demo mode: these packets are generated from the demo curve and decoded by the same code a real sensor uses.",
                          systemImage: "play.circle")
                        .font(.footnote)
                }
            }

            Section("NFC reads") {
                if sensor.nfcRecords.isEmpty {
                    Text("No NFC reads yet. Pair or scan a sensor.").foregroundStyle(.secondary)
                }
                ForEach(sensor.nfcRecords) { record in
                    NavigationLink {
                        NFCDetailView(record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(record.sensorType.displayName).font(.body.weight(.medium))
                                Spacer()
                                StatusTag(ok: record.error == nil)
                            }
                            Text("\(record.date.formatted(date: .abbreviated, time: .standard)) · \(record.encrypted.count) bytes")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Bluetooth packets (newest first)") {
                if sensor.packets.isEmpty {
                    Text("No packets yet.").foregroundStyle(.secondary)
                }
                ForEach(sensor.packets) { packet in
                    NavigationLink {
                        PacketDetailView(record: packet, unit: model.unit)
                    } label: {
                        PacketRow(record: packet, unit: model.unit)
                    }
                }
            }
        }
        .navigationTitle("Sensor data")
    }
}

struct StatusTag: View {
    let ok: Bool

    var body: some View {
        Text(ok ? "CRC OK" : "ERROR")
            .font(.caption2.bold().monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(ok ? Color.green : Color.red)
            .background((ok ? Color.green : Color.red).opacity(0.12), in: Capsule())
    }
}

struct PacketRow: View {
    let record: SensorConnection.PacketRecord
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.date.formatted(date: .omitted, time: .standard)).font(.body.monospacedDigit())
                if let latest = record.packet?.latest {
                    Text("age \(latest.minuteIndex) min").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusTag(ok: record.error == nil)
            }
            if let latest = record.packet?.latest, let reading = record.readings.first(where: { $0.minuteIndex == latest.minuteIndex }) {
                Text("raw \(latest.raw) → \(unit.format(mgdL: reading.mgdL, includeSymbol: true))")
                    .font(.caption.monospaced())
            }
            Text(record.encrypted.prefix(16).hexString + " …")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Colors for byte regions, matched to the legend.
enum RegionColor {
    static func color(_ name: String) -> Color {
        switch name {
        case "Seed": return .orange
        case "Encrypted": return .gray
        case "Trend": return .blue
        case "History": return .purple
        case "Sensor age": return .orange
        case "CRC", "Body CRC + indexes": return .pink
        case "Header": return .teal
        case "Footer": return .brown
        default: return .gray
        }
    }
}

/// Bytes in a grid, colored by the region each byte belongs to.
struct HexGrid: View {
    let bytes: [UInt8]
    let regions: [LibreLayout.Region]
    var columns = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
                ForEach(Array(bytes.enumerated()), id: \.offset) { index, byte in
                    let region = LibreLayout.region(of: index, in: regions)
                    Text(String(format: "%02X", byte))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RegionColor.color(region?.name ?? "").opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
                        .accessibilityLabel("Byte \(index): \(byte)")
                }
            }
            ForEach(regions, id: \.self) { region in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(RegionColor.color(region.name).opacity(0.6)).frame(width: 12, height: 12)
                        .padding(.top, 2)
                    VStack(alignment: .leading) {
                        Text("\(region.name) · bytes \(region.range.lowerBound)-\(region.range.upperBound - 1)").font(.caption.bold())
                        Text(region.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct PacketDetailView: View {
    let record: SensorConnection.PacketRecord
    let unit: GlucoseUnit

    var body: some View {
        List {
            Section {
                MetricRow(label: "Received", value: record.date.formatted(date: .abbreviated, time: .standard))
                MetricRow(label: "Source", value: record.isSimulated ? "Simulated (demo)" : "Bluetooth")
                if let packet = record.packet {
                    MetricRow(label: "Sensor age", value: "\(packet.ageMinutes) min (\(String(format: "%.1f", Double(packet.ageMinutes) / 1440)) days)")
                }
                if let error = record.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }

            Section("1. As received (46 bytes)") {
                HexGrid(bytes: record.encrypted, regions: LibreLayout.blePacket)
            }

            if let decrypted = record.decrypted {
                Section("2. Decrypted (44 bytes)") {
                    HexGrid(bytes: decrypted, regions: LibreLayout.bleDecrypted)
                }
            }

            if let packet = record.packet {
                Section {
                    ReadingTable(rows: (packet.trend + packet.history).map { raw in
                        ReadingTable.Row(raw: raw, ageMinutes: packet.ageMinutes,
                                         mgdL: record.readings.first { $0.minuteIndex == raw.minuteIndex }?.mgdL)
                    }, unit: unit)
                } header: {
                    Text("3. Readings in this packet")
                } footer: {
                    Text("Each reading is 4 bytes: bits 0-13 raw glucose signal, 14-25 raw temperature, 26-30 temperature adjustment, 31 its sign. \"Estimate\" is raw ÷ 8.5; \"Value\" uses your calibration.")
                }
            }
        }
        .navigationTitle("Packet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReadingTable: View {
    struct Row: Identifiable {
        var id: Int { raw.minuteIndex * 2 + (raw.isHistory ? 1 : 0) }
        let raw: LibreRawReading
        let ageMinutes: Int
        let mgdL: Double?
    }

    let rows: [Row]
    let unit: GlucoseUnit

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("When").gridColumnAlignment(.leading)
                Text("Raw")
                Text("Temp")
                Text("Estimate")
                Text("Value")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    Text(row.raw.minuteIndex == row.ageMinutes ? "now" : "−\(row.ageMinutes - row.raw.minuteIndex) min"
                         + (row.raw.isHistory ? " (h)" : ""))
                        .gridColumnAlignment(.leading)
                    Text("\(row.raw.raw)")
                    Text("\(row.raw.rawTemperature)")
                    Text(unit.format(mgdL: Double(row.raw.raw) / 8.5))
                    Text(row.mgdL.map { unit.format(mgdL: $0) } ?? "–")
                        .foregroundStyle(row.mgdL.map(RangeColor.color(for:)) ?? .secondary)
                        .bold()
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

struct NFCDetailView: View {
    @Environment(AppModel.self) private var model
    let record: SensorConnection.NFCRecord

    var body: some View {
        List {
            Section {
                MetricRow(label: "Read", value: record.date.formatted(date: .abbreviated, time: .standard))
                MetricRow(label: "Source", value: record.isSimulated ? "Simulated (demo)" : "NFC")
                MetricRow(label: "Sensor type", value: record.sensorType.displayName)
                MetricRow(label: "Serial (computed)", value: LibreSerial.serial(uid: record.uid, patchInfo: record.patchInfo))
                if let error = record.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                LabeledContent("UID") { Text(record.uid.hexString).font(.caption.monospaced()) }
                LabeledContent("Patch info") { Text(record.patchInfo.hexString).font(.caption.monospaced()) }
                if let response = record.streamingResponse {
                    LabeledContent("Enable response") { Text(response.hexString).font(.caption.monospaced()) }
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("UID: 8 bytes, shown in sensor byte order (E0 07 = manufacturer). Patch info byte 0 is the sensor type (\(String(format: "%02X", record.patchInfo.first ?? 0)) = \(record.sensorType.displayName)), byte 2's high nibble the family, byte 3 the region.")
            }

            if let fram = record.fram {
                Section("Decoded") {
                    MetricRow(label: "State", value: fram.state.description)
                    MetricRow(label: "Age", value: "\(fram.ageMinutes) min (\(String(format: "%.1f", Double(fram.ageMinutes) / 1440)) days)")
                    MetricRow(label: "Maximum life", value: "\(fram.maxLifeMinutes) min (\(fram.maxLifeMinutes / 1440) days)")
                    MetricRow(label: "Trend values (1 min)", value: "\(fram.trend.count)")
                    MetricRow(label: "History values (15 min)", value: "\(fram.history.count)")
                }
                Section("Trend: last 16 minutes") {
                    ReadingTable(rows: fram.trend.map { ReadingTable.Row(raw: $0, ageMinutes: fram.ageMinutes, mgdL: nil) }, unit: model.unit)
                }
                Section("History: last 8 hours") {
                    ReadingTable(rows: fram.history.map { ReadingTable.Row(raw: $0, ageMinutes: fram.ageMinutes, mgdL: nil) }, unit: model.unit)
                }
            }

            if let decrypted = record.decrypted {
                Section("Decrypted memory (344 bytes)") {
                    HexGrid(bytes: decrypted, regions: LibreLayout.fram)
                }
            }
            Section("As read over NFC (encrypted)") {
                HexGrid(bytes: record.encrypted, regions: [LibreLayout.Region(range: 0..<record.encrypted.count, name: "Encrypted",
                                                                              detail: "43 blocks of 8 bytes, each encrypted with its own key")])
            }
        }
        .navigationTitle("NFC read")
        .navigationBarTitleDisplayMode(.inline)
    }
}
