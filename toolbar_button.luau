--!strict
local Button = require("@ds/button")

type Props = Merge<ContainerProps, {
	lit: (() -> boolean)?,
	[number]: Child,
}>

return function(props: Props): Node
	local p = table.clone(props) :: any
	local lit = props.lit
	p.lit = nil
	p.tone, p.size, p.shape = "ghost", "xs", "pill"
	p.shrink, p.h = 0, 22
	p.items, p.justify = "center", "center"
	p.gap, p.px, p.py = "$space.1", "$space.2", 0
	p.font, p.text_size = "$font.mono", "$font.size.xs"
	p.bg = function(): string
		return if lit and lit() then "$hover" else "#00000000"
	end
	p.color = function(): string
		return if lit and lit() then "$accent" else "$text.tertiary"
	end
	p.hover = { bg = "$hover", color = "$accent" }
	p.active = { bg = "$pressed", color = "$accent" }
	return Button(p)
end
