import SwiftUI

/// Draws a Markdown table as a table: a header row, aligned cells, and its own horizontal scroll.
struct SparkChatTableView: View {
    let table: SparkChatTable.Table

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(table.headers.indices, id: \.self) { column in
                        Text(table.headers[column])
                            .font(.callout.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal).overlay(ChatStyle.border)
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            Text(table.rows[row][column]).font(.callout)
                        }
                    }
                }
            }
            .padding(16)
            .fixedSize(horizontal: true, vertical: false)
        }
        .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ChatStyle.border))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
