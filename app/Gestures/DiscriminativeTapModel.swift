import Foundation

// Balanced, regularized logistic model. Feature scaling and weights are fitted
// on training windows only. Unknown probabilities remain unclassified.
struct DiscriminativeTapModel {
    private var means=[Double](),scales=[Double](),weights=[Double]()
    private var bias=0.0
    init(features:[[Double]],labels:[Int]){
        guard let count=features.first?.count,count>0,features.count==labels.count,features.allSatisfy({$0.count==count && $0.allSatisfy(\.isFinite)}),labels.allSatisfy({$0==0 || $0==1}) else{return}
        let positives=labels.filter{$0==0}.count,negatives=labels.count-positives
        guard positives>=8,negatives>=8 else{return}
        means=(0..<count).map{i in features.reduce(0){$0+$1[i]}/Double(features.count)}
        scales=(0..<count).map{i in max(0.06,sqrt(features.reduce(0){$0+pow($1[i]-means[i],2)}/Double(features.count)))}
        let x=features.map{row in zip(zip(row,means),scales).map{($0.0.0-$0.0.1)/$0.1}}
        weights=Array(repeating:0,count:count)
        var first=Array(repeating:0.0,count:count+1),second=first
        for iteration in 1...300{
            var gradient=weights.map{$0*0.1};gradient.append(0)
            for i in x.indices{
                let z=max(-30,min(30,bias+zip(weights,x[i]).reduce(0){$0+$1.0*$1.1}))
                let error=(1/(1+exp(-z))-(labels[i]==0 ? 1:0))*0.5/Double(labels[i]==0 ? positives:negatives)
                for j in 0..<count{gradient[j]+=error*x[i][j]};gradient[count]+=error
            }
            for j in 0...count{
                first[j]=0.9*first[j]+0.1*gradient[j];second[j]=0.999*second[j]+0.001*gradient[j]*gradient[j]
                let step=0.03*(first[j]/(1-pow(0.9,Double(iteration))))/(sqrt(second[j]/(1-pow(0.999,Double(iteration))))+1e-8)
                if j<count{weights[j]-=step}else{bias-=step}
            }
        }
    }
    var ready:Bool{!weights.isEmpty}
    func probability(_ feature:[Double])->Double?{
        guard !weights.isEmpty,feature.count==weights.count,feature.allSatisfy(\.isFinite) else{return nil}
        let z=bias+zip(zip(zip(feature,means),scales),weights).reduce(0){$0+(($1.0.0.0-$1.0.0.1)/$1.0.1)*$1.1}
        return 1/(1+exp(-max(-30,min(30,z))))
    }
}
