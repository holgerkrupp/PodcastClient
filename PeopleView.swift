import SwiftUI



struct PeopleView: View {
    let people: [PersonInfo]
    let spacing: CGFloat

    init(people: [PersonInfo], spacing: CGFloat = 8) {
        self.people = people
        self.spacing = spacing
    }

    private var displayPeople: [PersonInfo] {
        // Keep order as-is; if you want ordering (e.g., by role), change here
        people
    }

    var body: some View {
        FlowRows(spacing: spacing) {
            ForEach(displayPeople) { person in
                Group {
                    if let href = person.href {
                        Link(destination: href) {
                            PersonChip(person: person)
                        }
                        .buttonStyle(.plain)
                    } else {
                        PersonChip(person: person)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People")
    }
}

private struct PersonChip: View {
    let person: PersonInfo

    var body: some View {
        HStack(spacing: 6) {
            if let img = person.img {
                AsyncImage(url: img) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().scaleEffect(0.7)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "person.crop.circle")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }

            Text(person.name)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct FlowRows: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = (currentRowWidth == 0 ? 0 : spacing) + size.width
            if currentRowWidth + neededWidth > maxWidth {
                totalHeight += currentRowHeight + (totalHeight == 0 ? 0 : spacing)
                currentRowWidth = size.width
                currentRowHeight = size.height
            } else {
                currentRowWidth += neededWidth
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                // wrap to next line
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("PeopleView - Sample") {
    let people: [PersonInfo] = [
        PersonInfo(name: "Alice Brown", role: "guest", href: URL(string: "https://www.wikipedia/alicebrown"), img: URL(string: "http://example.com/images/alicebrown.jpg")),
        PersonInfo(name: "Bob Smith", role: "host", href: nil, img: nil),
        PersonInfo(name: "Carol" , role: nil, href: URL(string: "https://example.com/carol"), img: nil)
    ]
    return PeopleView(people: people)
        .padding()
}
