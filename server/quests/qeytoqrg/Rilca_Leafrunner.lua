-- items: 15931, 15932, 15933, 15934, 15935
function event_spawn(e)
	eq.set_timer("depop",math.random(1200000,3600000));
end

function event_timer(e)
	if(e.timer == "depop") then
		eq.depop_with_timer();
	end
end

local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Rilca Leafrunner, a ranger of Surefall Glade patrolling the Qeynos Hills.",
    "You need adventurers to help gather gnoll intelligence — the gnolls are planning an invasion of Surefall Glade.",
    "You need four items brought from Blackburrow gnoll couriers: marching orders, invasion plans, area maps, and an encryption key.",
    "The gnolls oppose the rangers' plans to reopen the Jaggedpine entrance inside Surefall.",
    "You spawn and despawn on a random timer — you may not always be here.",
    "Valid keywords the player can ask about: [for me], [invasion], [Blackburrow], [Surefall].",
}

function event_say(e)
	if(e.message:findi("hail")) then
		e.self:Say("Well, it seems that you have something of importance that you wish to speak to me about? No? Then perhaps you can do something [for me].");
	elseif(e.message:findi("for you") or e.message:findi("for me")) then
		e.self:Say("Well I need some information. It appears that some gnolls are planning an [invasion] of Surefall. I believe there are some gnoll couriers that are running information. If you could bring me their marching orders, invasion plans, area maps, and their encryption key. Your best chance to catch a courier is probably inside Blackburrow.");
	elseif(e.message:findi("invasion")) then
		e.self:Say("Apparently they've heard of our plans to reopen the entrance to Jaggedpine inside Surefall. It seems they believe the think they have a chance to stop us. While most of us have little concern about a gnoll invasion force the information you provide would be of great assistance.");
	else
		-- LLM fallback: player said something off-keyword
		llm_bridge.send_thinking_indicator(e)
		local context = llm_bridge.build_quest_context(e, quest_hints)
		local response = llm_bridge.generate_response(context, e.message)
		if response then e.self:Say(response) end
	end
end

function event_trade(e)
	local item_lib = require("items");

	if(item_lib.check_turn_in(e.trade, {item1 = 15931,item2 = 15932,item3 = 15933,item4 = 15934})) then
		e.self:Emote("takes a look at the documents you handed her and smiles, 'This is exactly what we needed. We'll be better prepared if the gnolls are foolish enough to actually attack. I hope you are willing to assist us in the defense of Surefall. Should you choose to aid us, this club will serve you well.'");
		e.other:SummonItem(15935); -- Item: Club of Gnoll Bashing
		e.other:Ding();
		e.other:AddEXP(15000);
	end
	item_lib.return_items(e.self, e.other, e.trade)
end
