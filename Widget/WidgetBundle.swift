//
//  WidgetBundle.swift
//  Widget
//
//  Created by Swastik on 20/08/26.
//

import WidgetKit
import SwiftUI

@main
struct NoBarsWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoBarsWidget()
        WidgetControl()
        WidgetLiveActivity()
    }
}
