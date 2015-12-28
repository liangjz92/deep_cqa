--[[
	使用rnn的LSTM代码实现正确答案和错误答案的分类	
	author:	liangjz
	time:	2015-12-22
--]]
require('..')
local cfg = {}
cfg.vecs = nil
cfg.dict = nil
cfg.emd = nil
cfg.dim = deep_cqa.config.emd_dim
cfg.batch  = 50 or deep_cqa.config.batch_size
-- deep_cqa.ins_meth.load_binary()	--保险数据集，这里载入是为了获得测试集和答案
-----------------------
function get_index(sent)
	--	获取一个句子的索引表达，作为整个模型的输入，可以直接应用到词向量层
	if cfg.dict == nil then
		--	载入字典和词向量查询层
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
	------------------------------------
	--下面是cos sim的计算nn图
	local m1 = nn.ConcatTable()
	m1:add(nn.Identity())
	m1:add(nn.Identity())
	local m2 = nn.Sequential()
	m2:add(m1)
	m2:add(nn.CMulTable())
	m2:add(nn.Sum(2))
	m2:add(nn.Reshape(1))
	local m3 = m2:clone()
	local m4 = nn.ParallelTable()
	m4:add(m2)
	m4:add(m3)
	local m5 = nn.Sequential()
	m5:add(m4)
	m5:add(nn.MM(false,true))
	m5:add(nn.Sqrt())
	local m6 = nn.ConcatTable():add(nn.MM(false,true)):add(m5)
	local m7 = nn.Sequential():add(m6):add(nn.CDivTable())
	local cosine = m7
	-- cos 相似度模块构建完成
------------------------------------

	local cov = nn.Sequential()
	cov:add(nn.Replicate(1))	--增加维度的功能，好不容易才发现
	cov:add(nn.SpatialConvolution(1,200,3,3,1,1,2,2))	--input需要是3维tensor
	cov:add(nn.SpatialAdaptiveMaxPooling(1,1))
	cov:add(nn.Reshape(200))
	cov:add(nn.Tanh())
	
-------------------------------------
	local lm = {}	--待返回的语言模型
	lm.emd = cfg.emd	--词嵌入部分
-------------------------------

	return lm

end
function testlm()	--应用修改模型后测试模型是否按照预期执行
	local lm = getlm()
	local criterion = nn.MarginCriterion(1)
	local gold = torch.Tensor({0.5})

	local index1 = get_index('today is a good day'):clone()
	local index2 = get_index('today is a very good day'):clone()
	local index3 = get_index('This class creates an output where the input is replicated'):clone()
	local vec1 = lm.emd:forward(index1):clone()
	local vec2 = lm.emd:forward(index2):clone()
	local vec3 = lm.emd:forward(index3):clone()

end

cfg.lm = getlm()
-------------------------
function train()
	local lm = cfg.lm
	
	local modules = nn.Parallel():add(lm.emd)
	modules:add(lm.qlstm)
	modules:add(lm.tlstm)
	modules:add(lm.flstm)
	modules:add(lm.tq)
	modules:add(lm.fq)
	modules:add(lm.sub)
	params,grad_params = modules:getParameters()

	local train_set = torch.load(deep_cqa.ins_meth.train)
	local indices = torch.randperm(train_set.size)
	local criterion = nn.MarginCriterion(1):cuda()
	local gold = torch.Tensor({0.5}):cuda()
	local batch_size = cfg.batch
	local optim_state = {learningRate = 0.05 }
	--train_set.size =4000
	for i= 1,train_set.size,batch_size do
		local size = math.min(i+batch_size-1,train_set.size)-i+1
		local feval = function(x)
			grad_params:zero()
			local loss = 0	--累积的损失
			for j = 1,size do
				xlua.progress(i+j-1,train_set.size)
				local idx = indices[i+j-1]
				local sample = train_set[idx]
				local vecs={}
				for k =1,#sample do
					local index = get_index(sample[k]):clone():cuda()
					vecs[k] = lm.emd:forward(index):clone()
				end
				
				if(idx %2 ==0) then
					vecs[3],vecs[2] = vecs[2],vecs[3]
					gold[1] = -0.5
				else
					gold[1] = 0.5
				end

				local rep1 = lm.qlstm:forward(vecs[1])
				local rep2 = lm.tlstm:forward(vecs[2])
				local rep3 = lm.flstm:forward(vecs[3])
				local sc_1 = lm.tq:forward({rep1,rep2})
				local sc_2 = lm.fq:forward({rep1,rep3})
				local pred = lm.sub:forward({sc_1,sc_2})
				
				local loss = loss + criterion:forward(pred,gold)
				
				local e1 = criterion:backward(pred,gold)
				local e2 = lm.sub:backward({sc_1,sc_2},e1)
				local e3 = lm.tq:backward({rep1,rep2},e2[1])
				local e4 = lm.fq:backward({rep1,rep3},e2[2])
				local e5 = lm.qlstm:backward(vecs[1],(e3[1]+e4[1])/2)
				--local e6 = lm.qlstm:backward(vecs[1],e4[1])
				local e7 = lm.tlstm:backward(vecs[2],e3[2])
				local e8 = lm.flstm:backward(vecs[3],e4[2])
				
			end
			grad_params = grad_params/size
			loss = loss / size
			loss = loss + 1e-4*params:norm()^2
			return loss,grad_params		
		end
		optim.adagrad(feval,params,optim_state)
	end
end
------------------------------------------------------------------------
function test_one_pair(qst,ans)
	--给定一个问答pair，计算其相似度	
	--传入的qst为已经计算好的向量，ans为未经处理的句子
--[
	local lm = cfg.lm
	local aidx = get_index(ans):cuda()
	local aemd = lm.emd:forward(aidx):clone()
	local alstm = lm.tlstm:forward(aemd)
	local sim_sc = lm.tq:forward({qst,alstm})
	return sim_sc
--]
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
		
		local qidx = get_index(qst):cuda()
		local qemd = lm.emd:forward(qidx):clone()
		local qvec = lm.qlstm:forward(qemd)
		
		local sc = {}	
		local gold_sc ={}
		local gold_rank = {}
		
		for k,c in pairs(gold) do 
			c =tostring(tonumber(c))
			local score = test_one_pair(qvec,answer_set[c])[1]	--标准答案的得分
			gold_sc[k] = score
			gold_rank[k] = 1	--初始化排名
		end
		thr = 20
		for k,c in pairs(candidates) do 
			thr = thr -1
			if thr ==0 then break end
			c =tostring(tonumber(c))
			local score = test_one_pair(qvec,answer_set[c])[1]
			for m,n in pairs(gold_sc) do
				if score > n then
					gold_rank[m] = gold_rank[m]+1
				end
			end
		end
		
		local mark =false
		local mrr = 0
		for k,c in pairs(gold_rank) do
			if c==1 then 
				mark = true
			end
			mrr = mrr + 1.0/c
		end
		--print(mrr,i)
		if mark then 
			results[i] = {mrr,1.0}
		else
			results[i] = {mrr,0.0}
		end

	end
	local results = torch.Tensor(results)
	print(torch.sum(results,1)/results:size()[1])
end
getlm()
testlm()
--train()
--evaluate('dev')

