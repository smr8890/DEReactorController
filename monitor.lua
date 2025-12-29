--config
reactor = peripheral.wrap("")
outGate = peripheral.wrap("")
inGate = peripheral.wrap("")
monitor = peripheral.find("monitor")

function reactorInfo()
    return reactor.getReactorInfo()
end

function monitorWrite(x, y, text)
    monitor.setCursorPos(x, y)
    monitor.write(text)
end

function statusDisplay(info, input, output)
    monitor.clear()
    monitorWrite(1, 1, "Status: " .. info.status .. "\n")
    monitorWrite(1, 3, string.format("Temperature: %.2f C\n", info.temperature))
    --控制场强度
    local controlRate = info.fieldStrength / info.maxFieldStrength * 100
    monitorWrite(1, 5, string.format("Field Strength: %.2f %%\n", controlRate))
    --能量储量百分比
    local energyPercent = info.energySaturation / info.maxEnergySaturation * 100
    monitorWrite(1, 7, string.format("Energy Saturation: %.2f %%\n", energyPercent))
    --燃料消耗百分比
    local fuelPercent = info.fuelConversion / info.maxFuelConversion * 100
    monitorWrite(1, 9, string.format("Fuel Consumption: %.2f %%\n", fuelPercent))
    --FE产出
    monitorWrite(1, 11, string.format("FE Output: %.2fM FE/t\n", (output - input) / 1000000))
end

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

function main()
    if monitor then
        sleep(0.5)
        print("Monitor is running.")
        --监控主循环
        local info = reactorInfo()

        while info.status ~= "cold" do
            info = reactorInfo()
            local input = inGate.getFlow()
            local output = outGate.getFlow()
            statusDisplay(info, input, output)
            sleep0()
        end

        --最终停机
        if info.status == "cold" then
            monitor.clear()
            monitorWrite(1, 1, "Reactor stopped.\n")
        end

        print("Monitor stopped.")
    end
end

main()
