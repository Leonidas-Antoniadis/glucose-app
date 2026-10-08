import SwiftUI
import GlucoseCore

/// What a good MARD is, how this app calibrates, and when to calibrate, with links to the
/// xDrip+ documentation the advice comes from.
struct CalibrationGuideView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let u = model.unit
        List {
            Section {
                Text("MARD is the average difference between the sensor and your meter, in percent. In lab studies the Libre 2 Plus reaches about 8 %. This app compares with your meter, which has its own error (often 5–10 %), so expect a little higher.")
                GuideRow(mark: "Under 10 %", text: "Very good.")
                GuideRow(mark: "10–15 %", text: "Fine.")
                GuideRow(mark: "Over 15 %", text: "Something is off: the sensor, the calibration, or how you test.")
                Text("About 10 checks give a rough idea, 20 or more a reliable number. Every fingerstick counts, also one used to calibrate: it's compared with the value shown before calibrating.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("What's a good MARD")
            }

            Section {
                Text("Abbott's conversion isn't public, so the app draws a line from the sensor's raw signal to your fingersticks.")
                GuideRow(mark: "4 days", text: "It uses the calibrations from the last 4 days. Newer ones count more.")
                GuideRow(mark: "Two levels", text: "For the slope it needs two calibrations at least \(u.format(mgdL: 40, includeSymbol: true)) apart, say one near \(u.format(mgdL: 90)) and one near \(u.format(mgdL: 170)). Otherwise it only shifts every value up or down.")
                GuideRow(mark: "Kept", text: "The latest calibration stays until you calibrate again; it doesn't wear off.")
                GuideRow(mark: "Far off", text: "A fingerstick more than \(u.format(mgdL: 40, includeSymbol: true)) and 40 % away from the sensor waits for a second one within 30 minutes to agree, since that's more often a test error.")
            } header: {
                Text("How this app calibrates")
            }

            Section {
                GuideRow(mark: "1", text: "New sensor, first 1–2 days: 2–3 calibrations, one at a lower value and one at a higher one.")
                GuideRow(mark: "2", text: "Then stop calibrating routinely. Take one check a day with \"Use to calibrate\" off: it keeps measuring accuracy without changing anything.")
                GuideRow(mark: "3", text: "Calibrate again only when a check is red under Accuracy → Times it was off (more than \(u.format(mgdL: 20, includeSymbol: true)) or 20 %) and glucose is steady. Orange (15–20 %) can be meter error: calibrate only if the next check is off the same way.")
                GuideRow(mark: "4", text: "Check more often on the sensor's first and last days: sensors drift more then.")
                Text("Too many calibrations hurt: one taken while glucose is moving, or with sugar on the finger, pulls the line off. A few good ones beat many.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("When to calibrate")
            }

            Section {
                GuideRow(mark: "→", text: "Flat arrow, and no food or fast-acting insulin in the last 2 hours.")
                GuideRow(mark: "→", text: "Wash and dry your hands first: sugar on the finger gives a falsely high value.")
                GuideRow(mark: "→", text: "Not during the sensor's first hour (warm-up); the app refuses then anyway.")
            } header: {
                Text("Before you calibrate")
            }

            Section {
                Link(destination: URL(string: "https://xdrip.readthedocs.io/en/latest/calibrate/calibrate/")!) {
                    Label("xDrip+: how to calibrate", systemImage: "book")
                }
                Link(destination: URL(string: "https://xdrip.readthedocs.io/en/latest/calibrate/troubleshoot/")!) {
                    Label("xDrip+: calibration troubleshooting", systemImage: "wrench.and.screwdriver")
                }
                Link(destination: URL(string: "https://xdrip.readthedocs.io/en/latest/")!) {
                    Label("xDrip+ documentation (all)", systemImage: "books.vertical")
                }
                Link(destination: URL(string: "https://xdrip4ios.readthedocs.io/en/latest/configure/calibrate/")!) {
                    Label("xDrip4iOS: calibration", systemImage: "iphone")
                }
                Link(destination: URL(string: "https://pro.freestyle.abbott/uk-en/home/freestyle-portfolio/freestyle-libre-systems/freestyle-libre-2-plus-sensor.html")!) {
                    Label("Abbott: Libre 2 Plus accuracy", systemImage: "scope")
                }
            } header: {
                Text("Learn more")
            } footer: {
                Text("This follows community practice from xDrip+, not medical guidance. Check big changes with your diabetes team.")
            }
        }
        .navigationTitle("Calibration guide")
    }
}

/// A short bold mark (a number, a range) next to its explanation.
private struct GuideRow: View {
    let mark: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(mark)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 28, alignment: .leading)
                .fixedSize()
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
