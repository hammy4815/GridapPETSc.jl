using Gridap
using GridapPETSc
using GridapPETSc.PETSC
using PartitionedArrays
using SparseMatricesCSR
using Test
using LinearAlgebra

function partitioned_tests(parts)

  if length(parts) > 1

    noids,firstgid,hid_to_gid,hid_to_part = map_parts(parts) do part
      if part == 1
        3,1,[5,6],Int32[2,3]
      elseif part == 2
        2,4,[7,3,6],Int32[3,1,3]
      elseif part == 3
        2,6,[4],Int32[2]
      end
    end

    I,J,V = map_parts(parts) do part
      if part == 1
        I = [1,2,3,1,3]
        J = [1,2,3,5,6]
        V = [9,9,9,1,1]
      elseif part == 2
        I = [4,5,5,4,5]
        J = [4,5,3,6,7]
        V = [9,9,9,1,1]
      elseif part == 3
        I = [6,7,6]
        J = [6,7,4]
        V = [9,9,1]
      end
      I,J,Float64.(V)
    end

  else

    noids,firstgid,hid_to_gid,hid_to_part = map_parts(parts) do part
      7,1,Int[],Int32[]
    end

    I,J,V = map_parts(parts) do part
      I = [1,2,3,1,3,4,5,5,4,5,6,7,6]
      J = [1,2,3,5,6,4,5,3,6,7,6,7,4]
      V = [9,9,9,1,1,9,9,1,1,1,9,9,1]
      I,J,Float64.(V)
    end

  end

  GridapPETSc.Init(args=split("-ksp_type gmres -ksp_converged_reason -ksp_error_if_not_converged true -pc_type jacobi"))

  function test_get_local_vector(v::PVector,x::PETScVector)
    if (get_backend(v.values)==mpi)
      map_parts(parts) do part
        lg=GridapPETSc._get_local_oh_vector(x.vec[])
        @test isa(lg,PETScVector)
        lx=GridapPETSc._get_local_vector(lg)
        if part==1
          @test length(lx)==5
        elseif part==2
          @test length(lx)==5
        elseif part==3
          @test length(lx)==3
        end
        GridapPETSc._restore_local_vector!(lx,lg)
        GridapPETSc.Finalize(lg)
      end
    end
  end

  ngids = 7
  ids = PRange(parts,ngids,noids,firstgid,hid_to_gid,hid_to_part)
  values = map_parts(ids.partition) do ids
    println(ids.lid_to_gid)
    10.0*ids.lid_to_gid
  end

  function test_vectors(v::PVector,x::PETScVector,ids)
    PETSC.@check_error_code PETSC.VecView(x.vec[],C_NULL)
    u = PVector(x,ids)
    exchange!(u)
    map_parts(u.values,v.values) do u,v
      @test u == v
    end
  end

  v = PVector(values,ids)
  x = convert(PETScVector,v)
  test_get_local_vector(v,x)
  test_vectors(v,x,ids)

  if (get_backend(v.values)==mpi)
    # Copy v into v1 to circumvent (potentia) aliasing of v and x
    v1=copy(v)
    fill!(v1,zero(eltype(v)))
    copy!(v1,x)
    exchange!(v1)
    test_vectors(v1,x,ids)

    # Copy x into x1 to circumvent (potential) aliasing of v and x
    x1=copy(x)
    fill!(x1,PetscScalar(0.0))
    copy!(x1,v)
    test_vectors(v,x1,ids)
    GridapPETSc.Finalize(x1)
  end


  A = PSparseMatrix(I,J,V,ids,ids,ids=:global)
  display(A.values)
  B = convert(PETScMatrix,A)
  PETSC.@check_error_code PETSC.MatView(B.mat[],PETSC.@PETSC_VIEWER_STDOUT_WORLD)

  function solve_system_and_check_solution(A::PSparseMatrix,B::PETScMatrix,v)
     #TODO hide conversions and solver setup
     solver = PETScLinearSolver()
     ss = symbolic_setup(solver,B)
     ns = numerical_setup(ss,B)
     y = convert(PETScVector,A*v)
     x̂ = PETScVector(0.0,ids)
     solve!(x̂,ns,y)
     z = PVector(x̂,ids)
     exchange!(z)
     map_parts(z.values,v.values) do z,v
      @test maximum(abs.(z-v)) < 1e-5
     end
     GridapPETSc.Finalize(x̂)
     GridapPETSc.Finalize(y)
  end
  solve_system_and_check_solution(A,B,v)

  # Test that copy! works ok
  LinearAlgebra.fillstored!(B,PetscScalar(0.0))
  copy!(B,A)
  solve_system_and_check_solution(A,B,v)

  GridapPETSc.Finalize(B)
  GridapPETSc.Finalize(x)
  GridapPETSc.Finalize()
end
