//
// CapturedPassagesView.swift
//
// Review view listing all highlighted passages captured via the pinch-and-drag gesture.
//

import SwiftData
import SwiftUI

struct CapturedPassagesView: View {
  @Query(sort: \CapturedPassage.capturedAt, order: .reverse) private var passages: [CapturedPassage]
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var zoomedImage: UIImage?
  @State private var expandedPassageID: PersistentIdentifier?

  var body: some View {
    NavigationStack {
      Group {
        if passages.isEmpty {
          ContentUnavailableView(
            "No Highlighted Passages",
            systemImage: "text.highlight",
            description: Text("Pinch and hold for 0.3s, then drag across text to highlight a passage.")
          )
        } else {
          List {
            ForEach(passages) { passage in
              PassageRow(
                passage: passage,
                isExpanded: expandedPassageID == passage.persistentModelID,
                onToggleExpand: {
                  withAnimation(.spring(duration: 0.25)) {
                    if expandedPassageID == passage.persistentModelID {
                      expandedPassageID = nil
                    } else {
                      expandedPassageID = passage.persistentModelID
                    }
                  }
                },
                onTapImage: { image in
                  zoomedImage = image
                }
              )
            }
            .onDelete(perform: deletePassages)
          }
        }
      }
      .navigationTitle("Highlights")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          EditButton()
        }
      }
    }
    .fullScreenCover(item: $zoomedImage) { image in
      // Reuse ImageZoomView from CapturedWordsView (it's file-private there,
      // so we inline a simple version here)
      PassageImageZoomView(image: image) {
        zoomedImage = nil
      }
    }
  }

  private func deletePassages(at offsets: IndexSet) {
    for index in offsets {
      modelContext.delete(passages[index])
    }
  }
}

// MARK: - Row

private struct PassageRow: View {
  let passage: CapturedPassage
  let isExpanded: Bool
  let onToggleExpand: () -> Void
  let onTapImage: (UIImage) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Image thumbnail (if available)
      if let data = passage.imageData, let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: 120)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
          .contentShape(Rectangle())
          .onTapGesture { onTapImage(image) }
      }

      // Text
      Text(passage.text)
        .font(.body)
        .lineLimit(isExpanded ? nil : 3)
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }

      // Metadata
      HStack {
        Text(passage.capturedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        if !isExpanded && passage.text.count > 100 {
          Text("Tap to expand")
            .font(.caption2)
            .foregroundStyle(.blue)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Fullscreen Zoom

private struct PassageImageZoomView: View {
  let image: UIImage
  let onDismiss: () -> Void
  @State private var scale: CGFloat = 1.0
  @State private var offset: CGSize = .zero
  @GestureState private var gestureScale: CGFloat = 1.0
  @GestureState private var gestureOffset: CGSize = .zero

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .scaleEffect(scale * gestureScale)
        .offset(
          x: offset.width + gestureOffset.width,
          y: offset.height + gestureOffset.height
        )
        .gesture(
          MagnificationGesture()
            .updating($gestureScale) { value, state, _ in state = value }
            .onEnded { value in
              scale = max(1.0, scale * value)
            }
        )
        .simultaneousGesture(
          DragGesture()
            .updating($gestureOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
              offset.width += value.translation.width
              offset.height += value.translation.height
            }
        )
        .onTapGesture(count: 2) {
          withAnimation(.spring()) {
            scale = 1.0
            offset = .zero
          }
        }

      VStack {
        HStack {
          Spacer()
          Button {
            onDismiss()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 28))
              .foregroundStyle(.white, .white.opacity(0.3))
              .padding(16)
          }
        }
        Spacer()
      }
    }
  }
}
