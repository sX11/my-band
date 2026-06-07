//
//  Item.swift
//  My Band
//
//  Created by Matheus José on 07/06/26.
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
