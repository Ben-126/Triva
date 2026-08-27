//
//  Item.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
