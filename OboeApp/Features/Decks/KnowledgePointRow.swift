import OboeDomain
import SwiftUI

struct KnowledgePointRow: View {
    let item: KnowledgePointSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.headword)
                    .font(.headline)
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("已收藏")
                }
                Spacer()
                Text(item.kind == .vocabulary ? "单词" : "语法")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.kind == .vocabulary, let reading = item.reading {
                Text(reading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(item.meaningZH)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
