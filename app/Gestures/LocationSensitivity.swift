import Foundation

struct LocationSensitivity {
    let value:Double
    init(_ value:Double){self.value=value.isFinite ? min(1,max(0,value)):0.5}
    var positiveScore:Double{value<=0.5 ? 0.9-value*0.2:0.8-(value-0.5)*0.3}
    var minimumMargin:Double{value<=0.5 ? 0.4-value*0.3:0.25-(value-0.5)*0.2}
    var radiusScale:Double{value<=0.5 ? 0.75+value*0.5:1+(value-0.5)*0.8}
}
