-- testingg
local jest_globals = require(script.Parent.Parent.packages["jest-globals"])
local it = jest_globals.it
local expect = jest_globals.expect

return function()
    it("should pass", function()
        expect(true).to.equal(true)
        expect(1+1).to.equal(2)
    end)
end