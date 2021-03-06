--[[
	将CNN模型和基于词共现的结果结合起来，看实验结果能否比单纯的CNN要提高
	使用训练好的CNN模块作为初始化，只训练logistic层
	author:	liangjz
	time:	2015-1-7
	这种方法不行
--]]
require('..')
local cfg = {}
cfg.vecs = nil
cfg.dict = nil
cfg.emd = nil
cfg.dim = deep_cqa.config.emd_dim
cfg.gpu = true
deep_cqa.ins_meth.load_binary()	--保险数据集，这里载入是为了获得测试集和答案
-----------------------
function get_index(sent)
	--	获取一个句子的索引表达，作为整个模型的输入，可以直接应用到词向量层
	if cfg.dict == nil then	--	载入字典和词向量查询层
		cfg.dict, cfg.vecs = deep_cqa.get_sub_embedding()
		cfg.emd = nn.LookupTable(cfg.vecs:size(1),cfg.dim)
		cfg.emd.weight:copy(cfg.vecs)
		cfg.vecs = nil
	end
	return deep_cqa.read_one_sentence(sent,cfg.dict)
end
------------------------------------------------------------------------
function getlm()
	get_index('today is')
-------------------------------------
	local lm = cfg.lm	--待返回的语言模型
	lm.norm = nn.Tanh()
	lm.lgtc_tq = nn.Sequential()
	lm.lgtc_tq:add(nn.JoinTable(1))
	lm.lgtc_tq:add(nn.Linear(2,1):cuda())
	lm.lgtc_tq:add(nn.Sigmoid():cuda())
	lm.lgtc_fq = lm.lgtc_tq:clone('weights','bias')
-------------------------------
	if cfg.gpu then
		lm.qemd:cuda()
		lm.temd:cuda()
		lm.femd:cuda()
		lm.qst:cuda()
		lm.tas:cuda()
		lm.fas:cuda()
		lm.qt:cuda()
		lm.qf:cuda()
		lm.sub:cuda()
		lm.norm:cuda()
		lm.lgtc_tq:cuda()
		lm.lgtc_fq:cuda()
	end
-------------------------------
	return lm
end
function testlm()	--应用修改模型后测试模型是否按照预期执行
	local lm = getlm()
	local cosim = CoSim()
	local criterion = nn.MarginCriterion(1)
	local gold = torch.Tensor({1})
	
	local index1 = get_index('today is a good day'):clone()
	local index2 = get_index('today is a very good day'):clone()
	local index3 = get_index('This class creates an output where the input is replicated'):clone()
	if cfg.gpu then
		criterion:cuda()
		gold =gold:cuda()
		index1 = index1:cuda()
		index2 = index2:cuda()
		index3 = index3:cuda()
	end
	local vec1 = lm.qemd:forward(index1):clone()
	local vec2 = lm.qemd:forward(index2):clone()
	local vec3 = lm.qemd:forward(index3):clone()
	
	local hl = nn.Linear(cfg.dim,200)
	local q =  lm.qst:forward(vec1)
	local t =  lm.tas:forward(vec2)
	local f =  lm.fas:forward(vec3)
	local qt = lm.qt:forward({q,t})
	local qf = lm.qf:forward({q,f})
	local ctq = cosim:get_score('today is a good day','today is a very good day')
	local cfq = cosim:get_score('today is a good day','This class creates an output where the input is replicated')
	ctq = torch.Tensor({ctq}):cuda()
	cfq = torch.Tensor({cfq}):cuda()
	cans = lm.norm:forward(ctq-cfq)
	local c1 = lm.lgtc_tq:forward({qt,cans})
	local c2 = lm.lgtc_fq:forward({qf,cans})
	local sub = lm.sub:forward({c1,c2})
	print('两个结果',c1,c2,sub)
end
--------------------------
cfg.cosim = CoSim()
-------------------------
function train()
	local lm = cfg.lm
	local modules = nn.Parallel()
	modules:add(lm.qst)
	modules:add(lm.tas)
	modules:add(lm.fas)
	modules:add(lm.tq)
	modules:add(lm.fq)
	modules:add(lm.sub)
	modules:add(lm.norm)
	modules:add(lm.lgtc_tq)
	modules:add(lm.lgtc_fq)
	params,grad_params = modules:getParameters()

	local train_set = torch.load(deep_cqa.ins_meth.train)
	local indices = torch.randperm(train_set.size)
	local criterion = nn.MarginCriterion(0.009)
	local gold = torch.Tensor({1})
	if cfg.gpu then
		criterion:cuda()
		gold = gold:cuda()
	end
	local batch_size = cfg.batch
	local learningRate = 0.01
	
	train_set.size =18540*10
	for i= 1,train_set.size do
		if i% 100 ==0 then 	xlua.progress(i,train_set.size) end
		local idx = indices[i]
		local sample = train_set[idx]
		local vecs={}
		local index ={}
				index[1] = get_index(sample[1]):clone()
		index[2] = get_index(sample[2]):clone()
		index[3] = get_index(sample[3]):clone()
		if(cfg.gpu) then
			 index[1] = index[1]:cuda() 
			 index[2] = index[2]:cuda() 
			 index[3]= index[3]:cuda() 
		end
		if i%2==0 then
			index[2],index[3] = index[3],index[2]
			gold[1] = -1
		else
			gold[1] = 1
		end
		
		vecs[1] = lm.qemd:forward(index[1]):clone()
		vecs[2] = lm.temd:forward(index[2]):clone()
		vecs[3] = lm.femd:forward(index[3]):clone()	
		
		local rep1 = lm.qst:forward(vecs[1])
		local rep2 = lm.tas:forward(vecs[2])
		local rep3 = lm.fas:forward(vecs[3])
				
		local sc_1 = lm.qt:forward({rep1,rep2})
		local sc_2 = lm.qf:forward({rep1,rep3})
		local ct_0 = torch.Tensor({cfg.cosim:get_score(sample[1],sample[2])}) 
		local ct_1 = torch.Tensor({cfg.cosim:get_score(sample[1],sample[3])}) 
		if cfg.gpu then ct_1 = ct_1:cuda() ct_0 = ct_0:cuda() end
		ct_1 = lm.norm:forward(ct_1)
		ct_0 = lm.norm:forward(ct_0)
		local ct_2 = lm.lgtc_tq:forward({sc_1,ct_0})
		local ct_3 = lm.lgtc_fq:forward({sc_2,ct_1})
		local pred = lm.sub:forward({ct_2,ct_3})	-- 因为是距离参数转换为相似度参数，所以是负样本减正样本
		criterion:forward(pred,gold)

		lm.sub:zeroGradParameters()
		lm.qt:zeroGradParameters()
		lm.qf:zeroGradParameters()
		lm.qst:zeroGradParameters()
		lm.tas:zeroGradParameters()
		lm.fas:zeroGradParameters()
		lm.qemd:zeroGradParameters()
		lm.temd:zeroGradParameters()
		lm.femd:zeroGradParameters()
		lm.lgtc_tq:zeroGradParameters()
		lm.lgtc_fq:zeroGradParameters()
					
		local e1 = criterion:backward(pred,gold)
		local ct_5 = lm.sub:backward({ct_2,ct_3},e1)
		local ct_6 = lm.lgtc_tq:backward({sc_1,ct_0},ct_5[1])
		local ct_7 = lm.lgtc_fq:backward({sc_2,ct_1},ct_5[2])
		local e3 = lm.qt:backward({rep1,rep2},ct_6[1])
		local e4 = lm.qf:backward({rep1,rep3},ct_7[1])
		
		local e5 = lm.qst:backward(vecs[1],(e3[1]+e4[1])/2)
		local e7 = lm.tas:backward(vecs[2],e3[2])
		local e8 = lm.fas:backward(vecs[3],e4[2])
	--	if i<000 then
		lm.lgtc_tq:updateParameters(learningRate)
		lm.lgtc_fq:updateParameters(learningRate)
	--	end
--[[
		lm.sub:updateParameters(learningRate)
		lm.qt:updateParameters(learningRate)
		lm.qf:updateParameters(learningRate)
		lm.qst:updateParameters(learningRate)
		lm.tas:updateParameters(learningRate)
		lm.fas:updateParameters(learningRate)
--]]
--[[
		lm.qemd:backward(index[1],e5)
		lm.qemd:updateParameters(learningRate)
		lm.temd:backward(index[2],e7)
		lm.temd:updateParameters(learningRate)
		lm.femd:backward(index[3],e8)
		lm.femd:updateParameters(learningRate)
--]]
	end
end
------------------------------------------------------------------------
function test_one_pair(qst,qemd,ans)
	--给定一个问答pair，计算其相似度 传入的qst为已经计算好的向量，ans为未经处理的句子
	local lm = cfg.lm
	local aidx = get_index(ans)
	local cont = cfg.cosim:get_score(qst,ans)
	cont_sc = torch.Tensor({cont})
	if cfg.gpu then aidx = aidx:cuda() cont_sc = cont_sc:cuda() end
	cont_sc = lm.norm:forward(cont_sc)
	local aemd = lm.temd:forward(aidx)
	local arep = lm.tas:forward(aemd)
	local cnn_sc = lm.qt:forward({qemd,arep})
	local sim_sc = lm.lgtc_tq:forward({cnn_sc,cont_sc})
	return sim_sc[1]
end
function evaluate(name)
	--评估训练好的模型的精度，top 1是正确答案的比例
	local test_set = deep_cqa.insurance[name]
	local answer_set = deep_cqa.insurance['answer']
	if(test_set == nil) then
		print('测试集载入为空！') return 
	end
	
	local lm = cfg.lm	--语言模型
	local results = {}
	print('test process:')
	for i,v in pairs(test_set) do
		xlua.progress(i,1000)
		local gold = v[1]	--正确答案的集合
		local qst = v[2]	--问题
		local candidates = v[3] --候选的答案
		local qidx = get_index(qst)
		if cfg.gpu then qidx = qidx:cuda() end
		local qemd = lm.qemd:forward(qidx):clone()
		local qvec = lm.qst:forward(qemd)
		
		local sc = {}	
		local gold_sc ={}
		local gold_rank = {}
		
		for k,c in pairs(gold) do 
			c =tostring(tonumber(c))
			local score = test_one_pair(qst,qvec,answer_set[c])	--标准答案的得分
			gold_sc[k] = score
			gold_rank[k] = 1	--初始化排名
		end
		for k,c in pairs(candidates) do 
			c =tostring(tonumber(c))
			local score = test_one_pair(qst,qvec,answer_set[c])
			for m,n in pairs(gold_sc) do
				if score > n then
					gold_rank[m] = gold_rank[m]+1
				end
			end
		end
		
		local mark =0.0
		local mrr = 0
		for k,c in pairs(gold_rank) do
			if c==1 then 
				mark = 1.0
			end
			mrr = mrr + 1.0/c
		end
		results[i] = {mrr,mark}
	if i%10==0 then collectgarbage() end
	--if i >99 then break end
	end
	local results = torch.Tensor(results)
	print(torch.sum(results,1)/results:size()[1])
end
--getlm()
--testlm()
cfg.lm = torch.load('model/cov_3.bin')
cfg.lm = getlm()
train()
torch.save('model/cov+context_003.bin',cfg.lm,'binary')
--cfg.lm = torch.load('model/cov+context_001.bin','binary')
evaluate('dev')
