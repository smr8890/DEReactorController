function main()
    fs.move("/startup.lua", "/temp")
    fs.move("/replace.lua", "/startup.lua")
    fs.move("/temp", "/replace.lua")
    os.run({}, "/startup.lua")
end

main()
