--[[
	写一些读取数据的函数
--]]
--------------------------------------------------------
--输入文件中每行都是一个句子，本函数将该文件转换成为词向量索引的矩阵格式
function deep_cqa.read_sentences(path,vocab)
	local sentences = {}
	local file = io.open(path,'r')
	local line
	while true do 
		line = file:read()
		if line == nil then 
			break 
		end

		local tokens = stringx.split(line)
		local len = #tokens
		local sent = torch.IntTensor(len)
		for i =1,len do
			local token = tokens[i]
			sent[i] = vocab:index(token)
		end
		sentences[#sentences+1] =sent
	end

	file:close()
	return sentences
end
--------------------------------------------------------
--将一个句子转换成为字典索引编码的格式，每个句子一个向量
function deep_cqa.read_one_sentece(sent,vocab)
	local tokens = stringx.split(sent)
	local vecs = torch.IntTensor(#tokens)
	for i = 1 , #tokens do
		local token = tokens[i]
		vecs[i] = vocab:index(token)
	end
	return vecs	--转换完毕返回转换后的向量
end
---------------------------------------------------------
--针对保险数据QA数据集设计的读取函数
function deep_cqa.ins_meth.load_train()
	local ip = deep_cqa.config.insurance.train
	local file = io.open(ip,'r')
	local line
	local train_set = {}
	while true do
		line = file:read()
		if line == nil then
			break
		end
		local list = line:split('\t')
		table.insert(train_set,{list[1],list[2]:split(' ')})
	end
	file:close()
	deep_cqa.insurance['train'] = train_set
end
-----------------------------------
function deep_cqa.ins_meth.load_answer()
	local ip = deep_cqa.config.insurance.answer
	local file = io.open(ip,'r')
	local line
	local answer_set = {}
	while true do
		line = file:read()
		if line == nil then
			break
		end
		local list = line:split('\t')
		answer_set[list[1]] = list[2]
	end
	deep_cqa.insurance['answer'] = answer_set
	print(#answer_set)
	file:close()
end
---------------------------------------
function deep_cqa.ins_meth.load_test(name)
	local ip = nil
	if name == 'dev' then
		ip = deep_cqa.config.insurance.dev
	end
	if name == 'test1' then
		ip = deep_cqa.config.insurance.test1
	end
	if name == 'test2' then
		ip = deep_cqa.config.insurance.test2
	end
	if ip == nil then 
		return nil
	end

	local file = io.open(ip,'r')
	local line
	local test_set = {}
	while true do
		line = file:read()
		if line == nil then
			break
		end
		local list = line:split('\t')
		table.insert(test_set,{list[1]:split(' '),list[2],list[3]:split(' ')})
	end
	deep_cqa.insurance[name] = test_set
	file:close()
end
---------------------------------------
--载入保险数据的整体执行函数
function deep_cqa.ins_meth.load_txt_dataset()
	deep_cqa.ins_meth.load_train()
	deep_cqa.ins_meth.load_answer()
	deep_cqa.ins_meth.load_test('dev')
	deep_cqa.ins_meth.load_test('test1')
	deep_cqa.ins_meth.load_test('test2')
end
function deep_cqa.ins_meth.save_binary()
	if deep_cqa.insurance == nil then
		return nil
	end
	local op = deep_cqa.config.insurance.binary
	torch.save(op,deep_cqa.insurance,'binary')
end
function deep_cqa.ins_meth.load_binary()
	local ip = deep_cqa.config.insurance.binary
	deep_cqa.insurance = torch.load(ip)
end
----------------------------------------
--保险数据集，构建合适的训练数据和测试数据
function deep_cqa.ins_meth.generate_train_set()
	local nsize = deep_cqa.config.insurance.negative_size
	local train = {}
	local dataset = deep_cqa.insurance
	local answer_size = deep_cqa.get_size(dataset['answer'])
	for num,item in pairs(dataset['train']) do
		print(num)
		local qst =item[1]
		for i = 1,#item[2] do
			local ta = dataset['answer'][item[2][i]]
			local fa = deep_cqa.insurance.random_negative_id(item[2],answer_size)
			print('generate',ta,fa)
		end
	end
end
------------------------
function deep_cqa.get_size(tab)
	local count =0
	for i,v in pairs(tab) do
		count = count + 1
	end
	return count
end
-------------------------
function deep_cqa.ins_meth.random_negative_id(list,size)
	--随机获取一个answer id，该id不在传入的列表当中
	math.randomseed(tostring(os.time()):reverse():sub(1, 7))
	local id =nil
	while true do
		local mark = nil
		id = math.random(1,size)
		id = tostring(id)
--		print('random',id,list,size)
		for i = 1, #list do
			if id == list[i] then
				mark =1
			end
		end
		if mark == nil then
			break
		end
	end
	return id
end
---------------
function deep_cqa.ins_meth.generate_test_set()
end
