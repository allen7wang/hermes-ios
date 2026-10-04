import SwiftUI

enum TimelineAnchor: Hashable {
    case message(String)
    case bottom
}

struct TimelineJumpRequest: Equatable, Hashable {
    let id = UUID()
    let contextID: String
    let messageID: String
}

/// Reading older messages or jumping to a result pauses following the live reply.
/// The explicit button returns to the bottom and resumes following.
struct ChatTimeline<Content: View>: View {
    let contextID: String
    let updateToken: String
    @Binding var jumpRequest: TimelineJumpRequest?
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
            .task(id: positionID) {
                let request = jumpRequest?.contextID == contextID ? jumpRequest : nil
                followsLatest = request == nil
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let request { proxy.scrollTo(TimelineAnchor.message(request.messageID), anchor: .top) }
                else { proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom) }
            }
            .onChange(of: updateToken) { _, _ in
                if followsLatest { proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom) }
            }
        }
    }

    private var positionID: String {
        if let request = jumpRequest, request.contextID == contextID { return contextID + "/" + request.id.uuidString }
        return contextID + "/latest"
    }
}
