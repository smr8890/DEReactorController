------------------------
-- Config：外设绑定
------------------------
-- 反应堆核心（Draconic Reactor Core）
reactor = peripheral.wrap("")

-- 输出能量的 Flux Gate（接储能/电网）
outGate = peripheral.wrap("")

-- 输入能量的 Flux Gate（给反应堆充能、稳态）
inGate = peripheral.wrap("")

------------------------
-- 基础工具函数
------------------------

-- 获取反应堆当前状态信息
-- 等同于 reactor.getReactorInfo()
function reactorInfo()
    return reactor.getReactorInfo()
end

-- 设置输入能量（inGate）
-- 用于维持护盾、温度、能量饱和
function setIn(value)
    -- 防止出现负值
    if value < 0 then
        inGate.setFlowOverride(0)
    else
        -- Flux Gate 最大限制：64,000,000 RF/t
        if value > 64000000 then
            inGate.setFlowOverride(64000000)
        else
            inGate.setFlowOverride(value)
        end
    end
end

-- 设置输出能量（outGate）
-- 即反应堆对外发电量
function setOut(value)
    -- 不允许负输出
    if value < 0 then
        outGate.setFlowOverride(0)
    else
        outGate.setFlowOverride(value)
    end
end

-------------------------------------------------
-- 预测 / 数学模型（反应堆最优运行核心）
-------------------------------------------------
startInfo = reactorInfo()
-- 最大燃料转化量
-- 144（mB/锭） * 9 * 8 = 10368
-- maxFuelConversion = 144 * 9 * 8
maxFuelConversion = startInfo.maxFuelConversion

-- 最大能量饱和度
-- maxEnergySaturation = maxFuelConversion * 96450.61728395062
maxEnergySaturation = startInfo.maxEnergySaturation

-- 燃料消耗系数，用于归一化 fuelConversion
-- convLVL = fuelConversion * fuelCoe - 0.3
fuelCoe = 1.3 / maxFuelConversion


-- 立方根函数（支持负数）
-- Lua 的 x^(1/3) 对负数会出问题
function cbrt(x)
    if x < 0 then
        return -(-x) ^ (1 / 3)
    else
        return x ^ (1 / 3)
    end
end

-- 计算【最优能量饱和度比例】
-- 返回值范围应在 (0,1)
-- 含义：energySaturation / maxEnergySaturation
-- 解三次方程 ax^3 + bx^2 + cx + d = 0,计算【最优能量饱和度比例】
function sloveBestEnergySaturationRate(a, b, c, d)
    local A = b / a
    local B = c / a
    local C = d / a
    local Q = (3 * B - A ^ 2) / 9
    local R = (9 * A * B - 27 * C - 2 * A ^ 3) / 54
    local D = Q ^ 3 + R ^ 2
    if D >= 0 then
        local S = cbrt(R + math.sqrt(D))
        local T = cbrt(R - math.sqrt(D))
        local root1 = -A / 3 + (S + T)
        return root1
    end
end

-- 基础最大发电能力
-- DE 反应堆的经验比例：maxEnergySaturation * 1.5%
baseMaxGen = math.floor(maxEnergySaturation * 0.015)


-- 计算最优【输出功率】
-- 决定 outGate 的值
function bestOutputRate(info, bestSatRate)
    -- 当前燃料阶段
    local convLVL = info.fuelConversion * fuelCoe - 0.3

    -- 燃料越后期，输出越高
    -- 能量饱和度越接近最优，输出越高
    return baseMaxGen * (1 + convLVL * 2) * (1 - bestSatRate)
end

-- 计算最优【输入功率】
-- 决定 inGate 的值
function bestInputRate(info, bestSatRate)
    -- 当前实际能量饱和比例
    local actualSatRate = info.energySaturation / maxEnergySaturation

    -- 如果当前能量不足，按实际值算；否则按最优值算
    local satRate = math.min(actualSatRate, bestSatRate)

    -- 基础稳定输入公式
    local tempRatio = 11
    if info.temperature < 8000 then
        tempRatio = 1
    elseif info.temperature > 10000 then
        tempRatio = 1 + (info.temperature - 8000) ^ 2 * 0.0000025
    end
    local normalRate =
        tempRatio * math.max(1 - satRate, 0.01) * baseMaxGen / 10.923556 / 0.93

    return normalRate
end

------------------------
-- 安全阈值
------------------------

-- 当燃料消耗超过 80%，认为燃料不足，自动停机
autoStopFuel = maxFuelConversion * 0.8


------------------------
-- 自适应 sleep
-- 减少 CPU 占用
------------------------
lastSleep = nil
function sleep0()
    if not lastSleep or os.clock() > lastSleep then
        os.sleep(0)
    else
        os.sleep(0.05)
    end
    lastSleep = os.clock()
end

------------------------
-- 主控制逻辑
------------------------
function main()
    --启动监控
    if multishell.getTitle(multishell.getCount()) ~= "monitor" then
        shell.run("bg", "monitor.lua")
    end

    local info = reactorInfo()

    -- 启动前检查燃料是否足够
    if info.fuelConversion > autoStopFuel then
        print("Not enough fuel, won't start.")
        return
    end

    --------------------------------
    -- 冷启动流程
    --------------------------------
    if info.status ~= "running" then
        -- 启用 Flux Gate override
        inGate.setOverrideEnabled(true)
        outGate.setOverrideEnabled(true)

        -- 进入充能状态
        reactor.chargeReactor()

        -- 启动阶段：不输出，全力输入
        setOut(0)
        setIn(64000000)

        -- 等待达到启动条件
        while true do
            info = reactorInfo()
            if info.status == "running" then break end

            -- 满足温度、护盾、能量条件后激活反应堆
            if info.temperature >= 2000
                and info.fieldStrength >= info.maxFieldStrength * 0.49
                and info.energySaturation >= info.maxEnergySaturation * 0.49
            then
                reactor.activateReactor()
            end

            sleep0()
        end
    end

    --------------------------------
    -- 正常运行循环
    --------------------------------
    --启动前场强<15%时，先升场强至15%以上
    while info.status == "running" and info.fieldStrength <= info.maxFieldStrength * 0.15 do
        info = reactorInfo()
        -- setOut(0)
        setIn(64000000)
        sleep0()
    end
    while info.status == "running" do
        info = reactorInfo()

        -- 燃料不足，准备停机
        if info.fuelConversion > autoStopFuel then
            print("Not enough fuel, auto stop")
            break
        end

        -- 紧急条件：高温或场强过低
        if info.temperature >= 10005
            or info.fieldStrength <= info.maxFieldStrength * 0.15
        then
            setOut(0)
            setIn(64000000)
            reactor.stopReactor()
            print("Emergency stop!")
            return
        end

        -- 计算最优能量饱和度
        local A = info.fuelConversion * fuelCoe - 0.3

        local a = -970299
        local b = 2910897
        local c = 12474000 * A - 15241871.7
        local d = 126000 * A + 845743.7
        local bestSatRate = sloveBestEnergySaturationRate(a, b, c, d)

        -- 若模型返回异常值，直接停机
        if not (0 < bestSatRate and bestSatRate < 1) then
            setOut(0)
            setIn(64000000)
            reactor.stopReactor()
            print("Emergency stop!(Uncontrollable)")
            return
        end

        -- 动态调节输入/输出
        setIn(bestInputRate(info, bestSatRate))
        setOut(bestOutputRate(info, bestSatRate))

        sleep0()
    end

    --------------------------------
    -- 停机降温阶段
    --------------------------------
    while info.status == "running" do
        info = reactorInfo()

        -- 温度降到安全值后正式停机
        if info.temperature <= 6000 then
            reactor.stopReactor()
            break
        end

        -- 依然保留紧急保护
        if info.temperature >= 10005
            or info.fieldStrength <= info.maxFieldStrength * 0.02
        then
            setOut(0)
            setIn(64000000)
            reactor.stopReactor()
            print("Emergency stop!")
            return
        end

        -- 使用接近满饱和的策略安全降温
        setIn(bestInputRate(info, 0.99))
        setOut(bestOutputRate(info, 0.99))

        sleep0()
    end

    --------------------------------
    -- stopping 状态维稳
    --------------------------------
    info = reactorInfo()
    setOut(0)
    while info.status == "stopping" do
        -- 继续补能，防止护盾塌陷
        info = reactorInfo()
        setIn(bestInputRate(info, 0.99))
        sleep0()
    end
    setIn(0)
    print("Reactor stopped.")
end

-- 启动主程序
main()
