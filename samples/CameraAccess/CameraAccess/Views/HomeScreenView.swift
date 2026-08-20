/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HomeScreenView.swift
//
// Welcome screen that guides users through the DAT SDK registration process.
// This view is displayed when the app is not yet registered.
//

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  @ObservedObject var viewModel: WearablesViewModel
  var onPhoneCameraSelected: () -> Void = {}

  var body: some View {
    ZStack {
      Color.parchment.edgesIgnoringSafeArea(.all)

      VStack(spacing: Spacing.md) {
        Spacer()

        Image(.cameraAccessIcon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 120)

        VStack(spacing: Spacing.md) {
          HomeTipItemView(
            resource: .smartGlassesIcon,
            title: "Video Capture",
            text: "Record videos directly from your glasses, from your point of view."
          )
          HomeTipItemView(
            resource: .soundIcon,
            title: "Open-Ear Audio",
            text: "Hear notifications while keeping your ears open to the world around you."
          )
          HomeTipItemView(
            resource: .walkingIcon,
            title: "Enjoy On-the-Go",
            text: "Stay hands-free while you move through your day. Move freely, stay connected."
          )
        }

        Spacer()

        VStack(spacing: 12) {
          Text("Connect your glasses, or use your phone camera for testing.")
            .font(.system(size: 14))
            .foregroundColor(.leather)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.md)

          CustomButton(
            title: viewModel.registrationState == .registering ? "Connecting..." : "Connect my glasses",
            style: .primary,
            isDisabled: viewModel.registrationState == .registering
          ) {
            viewModel.connectGlasses()
          }

          CustomButton(
            title: "Use Phone Camera",
            style: .secondary,
            isDisabled: false
          ) {
            onPhoneCameraSelected()
          }
        }
      }
      .padding(.all, Spacing.xl)
    }
  }

}

struct HomeTipItemView: View {
  let resource: ImageResource
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(.ink)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, Spacing.xs)
        .padding(.top, Spacing.xs)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(title)
          .font(.serif(.headline, weight: .semibold))
          .foregroundColor(.ink)

        Text(text)
          .font(.system(size: 15))
          .foregroundColor(.leather)
      }
      Spacer()
    }
  }
}
