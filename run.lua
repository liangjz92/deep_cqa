require('.')
tmp = Trans2(true)
--tmp:testLM()
for i= 1,10 do
tmp:train(1)
tmp:evaluate('dev')
end
