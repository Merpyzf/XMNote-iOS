//
//  ReadingRoute.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import Foundation

enum ReadingRoute: Hashable {
    case bookDetail(bookId: UUID)
    case readingSession(bookId: UUID)
}
