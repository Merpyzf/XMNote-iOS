//
//  CollectionListPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

struct CollectionListPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "rectangle.stack", message: "暂无书单")
    }
}

#Preview {
    CollectionListPlaceholderView()
}
