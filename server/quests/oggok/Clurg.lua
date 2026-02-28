-- ## Written by Drogerin ##
-- items: 13378, 13379, 6359


local verified_loot = {

	3132,	--Large Ringmail Sleeves
	3128,	--Large Ringmail Coat
	3134,	--Large Ringmail Gloves
	3135,	--Large Ringmail Pants
	3136,	--Large Ringmail Boots
	13355,	--Crude Stein
	6006,	--Warhammer
	10024,	--Pearl
	6302,	--Ogre War Maul	
};


local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Clurg, the legendary ogre barkeep of Oggok — creator of the famous Flaming Clurg drink.",
    "You traveled across Norrath learning the barkeep's art and organized the Oggok Bouncers to maintain order.",
    "You compiled your drink recipes in a Barkeep Compendium — which was lost in Freeport and you want it returned.",
    "A Neriak barkeep named Pungla is selling a copycat drink called Flaming Pungla — you want his head.",
    "You will only discuss your secrets with those of indifferent or better faction — troublemakers get crushed by the Bouncers.",
    "Valid keywords: [unique drinks], [Bouncers], [rival guilds], [Flaming Clurg], [barkeeps in Freeport], [imposter drink], [special book].",
}

function event_say(e)
		local fac = e.other:GetFaction(e.self);
		if (e.message:findi("hail")) then
			e.self:Say("Hello, friend. Have a drink. I have some [" .. eq.say_link("unique drinks") .. "]. Try one. And remember. You get rowdy, the [" .. eq.say_link("Bouncers") .. "] crush you.");
		elseif (e.message:findi("unique drinks")) then
			e.self:Say("I have been all over Norrath and even served with some very great [" .. eq.say_link("barkeeps in Freeport") .. "]. I am the creator of both [" .. eq.say_link("Flaming Clurg") .. "] and Ogre Swill.");
		elseif (e.message:findi("Bouncers")) then
			e.self:Say("The Bouncers were organized by me. As I traveled to many of the world's taverns I encountered great enforcers called bouncers. It was their duty to keep order amongst chaos. When I returned and rose to greatness after the creation of the [" .. eq.say_link("Flaming Clurg") .. "]. I organized the Oggok Bouncers to keep order amongst the [" .. eq.say_link("rival guilds") .. "].");
		elseif (e.message:findi("rival guilds")) then
			e.self:Say("Oggok has been the battleground for the feud between the Greenblood knights and shamans and the Craknek warriors. It is fueled by the superior intellect of the Greenbloods. Few remember that I, Clurg, was once dim, but now I speak with great words.");
		elseif (e.message:findi("Flaming Clurg")) then
			e.self:Say("The Flaming Clurg was my greatest creation. It brought me great respect in Oggok. Unfortunately, I have heard tales of an [" .. eq.say_link("imposter drink") .. "].");
		elseif (e.message:findi("barkeeps in Freeport")) then
			e.self:Say("Yes. I have journeyed to many taverns, but it was in Freeport that I acquired most of my art. I compiled all my drink recipes in a [" .. eq.say_link("special book") .. "].");
		elseif (e.message:findi("imposter drink")) then
				if(fac <= 5) then -- Must be indifferent or higher for him to speak to you about this subject.
					e.self:Say("I have heard there is a barkeep who dares sell a similiar drink in Neriak's Foreign Quater. I have put a price on his head. Anyone who returns with his head shall be greatly rewarded.");
				else
					e.self:Say("Find ways to help all in Oggok. Then we will have conversation.");
				end
		elseif (e.message:findi("special book")) then
				if(fac <= 5) then -- Must be indifferent or higher for him to speak to you about this subject.
					e.self:Say("I compiled all my drinks into one book. I lost this book while in Freeport. No doubt some barkeep is experimenting with it. I would pay dearly for the return of my Barkeep Compendium.");
				else
					e.self:Say("Find ways to help all in Oggok. Then we will have conversation.");
				end
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
	local fac = e.other:GetFaction(e.self);
    if (item_lib.check_turn_in(e.trade, {item1 = 13378})) then -- Ogre Head "Identifies as Pungla's Head"
		if(fac <= 5) then --indifferent or higher is required here
			local prize = math.random(1, #verified_loot);
			e.self:Say("Haha! He shall mix no more Flaming Pungla's! I shall drink from his rotting skull tonight. As for you, take this and call it yours. Consider yourself a friend of Clurg.");
			e.other:Faction(228,15,0); --Clurg
			e.other:Faction(274,-15,0); --Kazon Stormhammer
			e.other:Faction(261,15,0); --Green Blood Knights
			e.other:Faction(232,15,0); --Craknek Warriors
			e.other:Faction(337,15,0); --Oggok Guards
                      e.other:SummonItem(verified_loot[prize]);
		else
			e.self:Say("Find ways to help all in Oggok. Then we will trade.");
			e.other:SummonItem(13378);	-- Ogre Head returned. Not enough faction
		end
    elseif (item_lib.check_turn_in(e.trade, {item1 = 13379})) then -- Barkeep Compendium
		if(fac <= 4) then -- Amiable turn in IS required. Indifferent handed book back.
			e.self:Say("Ahhh! My Barkeep Compendium has been returned! I am in your debt. I do not like to be in any man's debt. Let me offer you this as a payment for your great service. Obtaining my book could not have been a simple task.");
			e.other:Faction(228,50,0); --Clurg
			e.other:Faction(274,-50,0); --Kazon Stormhammer
			e.other:Faction(261,50,0); --Green Blood Knights
			e.other:Faction(232,50,0); --Craknek Warriors
			e.other:Faction(337,50,0); --Oggok Guards
			e.other:SummonItem(6359); -- Stein of Moggok
		else
			e.self:Say("Find ways to help all in Oggok. Then we will trade.");
			e.other:SummonItem(13379);	-- Compendium returned. Not enough faction @ indifferent
		end
	end
    item_lib.return_items(e.self, e.other, e.trade);
end
