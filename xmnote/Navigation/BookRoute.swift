//
//  BookRoute.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import Foundation

enum BookRoute: Hashable {
    case detail(bookId: UUID)
    case edit(bookId: UUID)
    case add
}
