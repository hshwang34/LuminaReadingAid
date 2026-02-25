//
// CapturedWordsView.swift
//
// Review view listing all words captured by the pointing gesture,
// each paired with a zoomed crop of the OCR scan region.
//

import SwiftData
import SwiftUI

struct CapturedWordsView: View {
  @Query(sort: \CapturedWord.capturedAt, order: .reverse) private var words: [CapturedWord]
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var zoomedImage: UIImage?

  var body: some View {
    NavigationStack {
      Group {
        if words.isEmpty {
          ContentUnavailableView(
            "No Captured Words",
            systemImage: "hand.point.up",
            description: Text("Point your index finger at a word and hold still to capture it.")
          )
        } else {
          List {
            ForEach(words) { entry in
              CapturedWordRow(entry: entry) { image in
                zoomedImage = image
              }
            }
            .onDelete(perform: deleteWords)
          }
        }
      }
      .navigationTitle("Captured Words")
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
      ImageZoomView(image: image) {
        zoomedImage = nil
      }
    }
  }

  private func deleteWords(at offsets: IndexSet) {
    for index in offsets {
      modelContext.delete(words[index])
    }
  }
}

// MARK: - Row

private struct CapturedWordRow: View {
  let entry: CapturedWord
  let onTapImage: (UIImage) -> Void

  var body: some View {
    HStack(spacing: 10) {
      // Original crop + preprocessed crop side by side
      HStack(spacing: 4) {
        CropThumbnail(data: entry.imageData, label: "orig", onTap: onTapImage)
        CropThumbnail(data: entry.preprocessedImageData, label: "proc", onTap: onTapImage)
      }

      VStack(alignment: .leading, spacing: 4) {
        if entry.text.isEmpty {
          Text("(no text)")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .italic()
        } else {
          Text(entry.text)
            .font(.title3.weight(.semibold))
        }
        Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }
}

// MARK: - Crop Thumbnail

private struct CropThumbnail: View {
  let data: Data?
  let label: String
  let onTap: (UIImage) -> Void

  var body: some View {
    if let data, let image = UIImage(data: data) {
      VStack(spacing: 2) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 90, height: 50)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
          .contentShape(Rectangle())
          .onTapGesture { onTap(image) }
        Text(label)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
      }
    } else {
      VStack(spacing: 2) {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.secondary.opacity(0.1))
          .frame(width: 90, height: 50)
          .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        Text(label)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Fullscreen Zoom

private struct ImageZoomView: View {
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

// MARK: - Identifiable conformance for fullScreenCover

extension UIImage: @retroactive Identifiable {
  public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
