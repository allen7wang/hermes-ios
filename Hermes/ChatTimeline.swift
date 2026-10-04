import SwiftUI

enum TimelineAnchor: Hashable {
    case message(String)
    case bottom
}

/// Reading older messages or jumping to a result pauses following the live reply.
/// The explicit button returns to the bottom and resumes following.
struct ChatTimeline<Content: View>: View {
    let contextID: String
    let updateToken: String
    @Binding var jumpID: String?
    @ViewBuilder let content: (ScrollViewProxy, @escaping () -> Void) -> Content
    @State private var followsLatest = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content(proxy, { followsLatest = false })
                Color.clear.frame(height: 1).id(TimelineAnchor.bottom)
            }
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) { followsLatest = false }
            })
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation { proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom) }
                    } label: {
                        Label("返回最新", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 12)
                            .background(HermesTheme.raised, in: Capsule())
                    }
                    .tint(HermesTheme.accent).padding(12)
                }
            }
            .task(id: contextID) {
                followsLatest = true
                await Task.yield()
                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
            }
            .onChange(of: updateToken) { _, _ in
                if followsLatest { proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom) }
            }
            .onChange(of: jumpID) { _, id in
                guard let id else { return }
                followsLatest = false
                withAnimation { proxy.scrollTo(TimelineAnchor.message(id), anchor: .top) }
                jumpID = nil
            }
        }
    }
}
