//
//  BookRoute.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import Foundation

enum BookRoute: Hashable {
    case detail(bookId: Int64)
    case edit(bookId: Int64)
    case add
}
