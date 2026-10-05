import SwiftUI

struct ScanBoundaryNotice: View {
    let inaccessibleCount: Int
    var skippedCount: Int = 0
    var wasTruncated = false

    var body: some View {
        if inaccessibleCount > 0 || skippedCount > 0 || wasTruncated {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some items were not fully checked")
                        .font(.subheadline.weight(.semibold))
                    Text(String(
                        format: String(localized: "%lld unavailable items · %lld skipped items"),
                        Int64(inaccessibleCount), Int64(skippedCount)
                    ))
                    .font(.caption)
                    if wasTruncated {
                        Text("The scan reached its safety limit; results are incomplete.")
                            .font(.caption)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tint.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Tint.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }
    }
}
