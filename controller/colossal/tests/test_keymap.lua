keys = {
    backspace=14, up=200, down=208, enter=28, s=31, a=30, f10=68,
    escape=1, one=2, two=3, three=4, four=5, five=6,
    r=19, c=46, p=25, x=45,
}

local Keymap = require("app.keymap")
local T = require("tests.mock_cc")

return {
    { name = "search input maps typing navigation and selection", run = function()
        T.equal(Keymap.command({"char","x"},{mode="search"}).text,"x")
        T.equal(Keymap.command({"paste","stone"},{mode="search"}).type,"QUERY_APPEND")
        T.equal(Keymap.command({"key",keys.backspace},{mode="search"}).type,"QUERY_BACKSPACE")
        T.equal(Keymap.command({"key",keys.up},{mode="search"}).delta,-1)
        T.equal(Keymap.command({"key",keys.down},{mode="search"}).delta,1)
        T.equal(Keymap.command({"key",keys.enter},{mode="search"}).type,"OPEN_QUANTITY")
    end },
    { name = "quantity shortcuts support one stack all and exact digits", run = function()
        T.equal(Keymap.command({"key",keys.enter},{mode="quantity",quantity_text=""}).quantity,"one")
        T.equal(Keymap.command({"key",keys.s},{mode="quantity"}).quantity,"stack")
        T.equal(Keymap.command({"key",keys.a},{mode="quantity"}).quantity,"all")
        local digit=Keymap.command({"char","7"},{mode="quantity"})
        T.equal(digit.type,"SET_QUANTITY")
        T.equal(digit.digit,"7")
        local exact=Keymap.command({"key",keys.enter},{mode="quantity",quantity_text="42"})
        T.equal(exact.type,"REQUEST")
        T.equal(exact.quantity,42)
    end },
    { name = "F10 cancels but Minecraft escape is never captured", run = function()
        T.equal(Keymap.command({"key",keys.f10},{mode="quantity"}).type,"CANCEL")
        T.equal(Keymap.command({"key",keys.escape},{mode="quantity"}),nil)
    end },
    { name = "number keys open every secondary page from search", run = function()
        T.equal(Keymap.command({"key",keys.one},{mode="search"}).page,"search")
        T.equal(Keymap.command({"key",keys.two},{mode="search"}).page,"storage")
        T.equal(Keymap.command({"key",keys.three},{mode="search"}).page,"requests")
        T.equal(Keymap.command({"key",keys.four},{mode="search"}).page,"alerts")
        T.equal(Keymap.command({"key",keys.five},{mode="search"}).page,"setup")
    end },
    { name = "mouse regions and scrolling translate into normal commands", run = function()
        local state={mode="search",hit_regions={{x1=2,y1=4,x2=20,y2=4,
            command={type="ACTIVATE",index=3}}}}
        local clicked=Keymap.command({"mouse_click",1,8,4},state)
        T.equal(clicked.type,"ACTIVATE")
        T.equal(clicked.index,3)
        T.equal(Keymap.command({"mouse_scroll",1,8,4},state).delta,1)
        T.equal(Keymap.command({"mouse_scroll",-1,8,4},state).delta,-1)
    end },
    { name = "variant chooser is keyboard complete", run = function()
        T.equal(Keymap.command({"key",keys.down},{mode="variant"}).delta,1)
        T.equal(Keymap.command({"key",keys.enter},{mode="variant"}).type,"ACTIVATE")
        T.equal(Keymap.command({"key",keys.f10},{mode="variant"}).type,"CANCEL")
    end },
    { name = "requests page supports selection movement, retry and cancel", run = function()
        local state={mode="page",page="requests"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.r},state).type,"RETRY_REQUEST")
        T.equal(Keymap.command({"key",keys.c},state).type,"CANCEL_REQUEST")
    end },
    { name = "alerts page supports selection movement and acknowledgement", run = function()
        local state={mode="page",page="alerts"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.a},state).type,"ACKNOWLEDGE_ALERT")
    end },
    { name = "storage page scrolls but has no retry or acknowledge shortcuts", run = function()
        local state={mode="page",page="storage"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.r},state),nil)
        T.equal(Keymap.command({"key",keys.a},state),nil)
    end },
    { name = "recovery release on the alerts page requires a deliberate two key confirm", run = function()
        local state={mode="page",page="alerts"}
        local armed=Keymap.command({"key",keys.x},state)
        T.equal(armed.type,"ARM_RECOVERY_RELEASE")
        local armedState={mode="page",page="alerts",recovery_confirm_armed=true}
        T.equal(Keymap.command({"key",keys.x},armedState).type,"ARM_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.enter},armedState).type,"CONFIRM_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.up},armedState).type,"CANCEL_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.f10},armedState).type,"CANCEL_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.a},armedState).type,"CANCEL_RECOVERY_RELEASE")
    end },
    { name = "P toggles pause outside the search text box but never while typing", run = function()
        T.equal(Keymap.command({"key",keys.p},{mode="page",page="requests"}).type,"TOGGLE_PAUSE")
        T.equal(Keymap.command({"key",keys.p},{mode="quantity"}).type,"TOGGLE_PAUSE")
        T.equal(Keymap.command({"key",keys.p},{mode="search"}),nil)
    end },
    { name = "number tab shortcuts suppress only their paired character", run = function()
        local open=Keymap.command({"key",keys.one},{mode="search",query=""})
        T.equal(open.type,"OPEN_PAGE")
        T.equal(open.suppress_char,"1")
        local consume=Keymap.command({"char","1"},{mode="search",query="",suppress_char="1"})
        T.equal(consume.type,"CONSUME_CHAR")
        local tab=Keymap.command({"key",keys.two},{mode="search",query="mod"})
        T.equal(tab and tab.page,"storage")
        T.equal(Keymap.command({"char","1"},{mode="search",query="mod"}).text,"1")
    end },
}
