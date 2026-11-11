import Foundation

public enum FoxCodeParser {
    /// 仅接受同源仪表板接口的明确成功响应，拒绝页面尚未加载时的默认零值。
    public static func parse(data: Data, at date: Date = Date()) throws -> BalanceReading {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success, response.subscriptions.count <= 10_000 else {
            throw BalanceError.unavailable("FoxCode 未返回有效额度，请检查登录状态")
        }
        var payg = 0.0, monthly = 0.0
        for subscription in response.subscriptions {
            let used = subscription.quotaUsed, limit = subscription.plan.quotaLimit
            guard used.isFinite, limit.isFinite, used >= 0, limit >= 0,
                  used <= 9_007_199_254_740_991, limit <= 9_007_199_254_740_991,
                  !subscription.plan.resetType.isEmpty else {
                throw BalanceError.unavailable("FoxCode 额度字段异常，保留上次数据")
            }
            if subscription.plan.resetType == "NEVER" { payg += limit - used }
            else { monthly += limit - used }
        }
        guard payg.isFinite, monthly.isFinite else { throw BalanceError.unavailable("FoxCode 额度字段异常") }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN"); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 3
        func formatted(_ number: Double) -> String { formatter.string(from: NSNumber(value: number)) ?? String(number) }
        return BalanceReading(service: .foxcode, metrics: [
            BalanceMetric(id: "payg", label: "按量剩余额度", value: formatted(payg)),
            BalanceMetric(id: "monthly", label: "月卡剩余额度", value: formatted(monthly))
        ], fetchedAt: date, source: "FoxCode 仪表板接口")
    }
    private struct Response: Decodable { let success: Bool; let subscriptions: [Subscription] }
    private struct Subscription: Decodable { let quotaUsed: Double; let plan: Plan }
    private struct Plan: Decodable { let quotaLimit: Double; let resetType: String }
}
