!
! Copyright (C) 2001-2004 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
#include "machine.h"
!
!----------------------------------------------------------------------------
SUBROUTINE c_bands( iter, ik_, dr2 )
  !----------------------------------------------------------------------------
  !
  ! ... this is a wrapper to specific calls
  !
  ! ... internal procedures :
  !
  ! ... c_bands_gamma()   : for gamma sampling of the BZ (optimized algorithms)
  ! ... c_bands_k()       : for arbitrary BZ sampling (general algorithm)
  ! ... test_exit_cond()  : the test on the iterative diagonalization
  !
  !
  USE kinds,                ONLY : DP
  USE io_global,            ONLY : stdout
  USE wvfct,                ONLY : gamma_only
  USE io_files,             ONLY : iunigk, nwordatwfc, iunat, iunwfc, nwordwfc
  USE brilz,                ONLY : tpiba2 
  USE klist,                ONLY : nkstot, nks, xk
  USE us,                   ONLY : okvan, vkb, nkb
  USE gvect,                ONLY : g, gstart, ecfixed, qcutz, q2sigma, nrxx, &
                                   nr1, nr2, nr3  
  USE wvfct,                ONLY : g2kin, wg, nbndx, et, nbnd, npwx, igk, &
                                   npw
  USE control_flags,        ONLY : diis_ndim, istep, ethr, lscf, max_cg_iter, &
                                   diis_ethr_cg, isolve, reduce_io
  USE ldaU,                 ONLY : lda_plus_u, swfcatom
  USE scf,                  ONLY : vltot
  USE lsda_mod,             ONLY : current_spin, lsda, isk
  USE wavefunctions_module, ONLY : evc  
  USE g_psi_mod,            ONLY : h_diag, s_diag
  !
  IMPLICIT NONE
  !
  ! ... First the I/O variables
  !
  INTEGER :: ik_, iter
    ! k-point already done
    ! current iterations
  REAL(KIND=DP) :: dr2
    ! current accuracy of self-consistency
  !
  ! ... local variables
  !
  REAL(KIND=DP) :: avg_iter, v_of_0
    ! average number of iterations
    ! the average of the potential
  INTEGER :: ik, ig, ibnd, dav_iter, ntry, notconv
    ! counter on k points
    ! counter on G vectors
    ! counter on bands
    ! number of iterations in Davidson
    ! number or repeated call to diagonalization in case of non convergence
    ! number of notconverged elements
  !
  ! ... external functions
  !
  REAL(KIND=DP), EXTERNAL :: dsum, erf
    ! summation function
    ! error function  
  !
  !
  CALL start_clock( 'c_bands' )
  !
  IF ( ik_ == nks ) THEN
     !
     ik_ = 0
     !
     RETURN
     !
  END IF
  !
  ! ... allocate arrays
  !
  ALLOCATE( h_diag( npwx ) )    
  ALLOCATE( s_diag( npwx ) )      
  !
  IF ( gamma_only ) THEN
     !
     CALL c_bands_gamma()
     !
  ELSE
     !
     CALL c_bands_k()
     !
  END IF  
  !
  ! ... deallocate arrays
  !
  DEALLOCATE( s_diag )
  DEALLOCATE( h_diag )
  !       
  CALL stop_clock( 'c_bands' )  
  !
  RETURN
  !
  CONTAINS
     !
     ! ... internal procedures
     !
     !-----------------------------------------------------------------------
     SUBROUTINE c_bands_gamma()
       !-----------------------------------------------------------------------
       !  
       ! ... This routine is a driver for the diagonalization routines of the
       ! ... total Hamiltonian at Gammma point only
       ! ... It reads the Hamiltonian and an initial guess of the wavefunctions
       ! ... from a file and computes initialization quantities for Davidson
       ! ... iterative diagonalization.
       !
       USE rbecmod, ONLY: becp, becp_
       !
       IMPLICIT NONE
       !
       !
       ! ... becp, becp_ contain <beta|psi> - used in h_psi and s_psi
       ! ... they are allocate once here in order to reduce overhead
       !
       ALLOCATE( becp( nkb, nbnd ), becp_( nkb, nbnd ) )
       !
       IF ( isolve == 0 ) THEN
          WRITE( stdout, '("     Davidson diagonalization with overlap")' )
       ELSE
          CALL errore( 'c_bands', &
                     & 'CG and DIIS diagonalization not implemented', 1 )
       END IF
       !
       avg_iter = 0.D0
       !
       ! ... v_of_0 is (Vloc)(G=0)
       !
       v_of_0 = dsum( nrxx, vltot, 1 ) / REAL( nr1 * nr2 * nr3 )
       !
#if defined (__PARA)
       CALL reduce( 1, v_of_0 )
#endif
       !
       IF ( nks > 1 ) REWIND( iunigk )
       !
       ! ... For each k point diagonalizes the hamiltonian
       !
       k_loop: DO ik = 1, nks
          !
          IF ( lsda ) current_spin = isk(ik)
          !
          ! ... Reads the Hamiltonian and the list k+G <-> G of this k point
          !
          IF ( nks > 1 ) READ( iunigk ) npw, igk
          !
          ! ... do not recalculate k-points if restored from a previous run
          !
          IF ( ik <= ik_ ) THEN
             !
             CALL save_in_cbands( iter, ik, dr2 )
             !
             CYCLE k_loop
             !
          END IF          
          !
          ! ... various initializations
          !
          IF ( nkb > 0 ) &
             CALL init_us_2( npw, igk, xk(1,ik), vkb )
          !
          ! ... read in wavefunctions from the previous iteration
          !
          IF ( nks > 1 .OR. .NOT. reduce_io ) &
             call davcio( evc, nwordwfc, iunwfc, ik, -1 )
          !
          ! ... Needed for LDA+U
          !
          IF ( lda_plus_u ) CALL davcio( swfcatom, nwordatwfc, iunat, ik, -1 )
          !
          ! ... sets the kinetic energy
          !
          g2kin(1:npw) = ( ( xk(1,ik) + g(1,igk(1:npw)) )**2 + &
                           ( xk(2,ik) + g(2,igk(1:npw)) )**2 + &
                           ( xk(3,ik) + g(3,igk(1:npw)) )**2 ) * tpiba2
          !
          IF ( qcutz > 0.D0 ) THEN
             !
             DO ig = 1, npw
                g2kin(ig) = g2kin(ig) + qcutz * &
                            ( 1.D0 + erf( (g2kin(ig) - ecfixed ) / q2sigma ) )
             END DO
             !
          END IF
          !
          ! ... h_diag are the diagonal matrix elements of the 
          ! ... hamiltonian used in g_psi to evaluate the correction 
          ! ... to the trial eigenvectors
          !
          h_diag(1:npw) = g2kin(1:npw) + v_of_0
          !
          CALL usnldiag( h_diag, s_diag )
          !
          ntry = 0
          !
          david_loop: DO
             !
             CALL regterg( npw, npwx, nbnd, nbndx, evc, ethr, okvan, gstart, &
                           et(1,ik), notconv, dav_iter )
             !
             avg_iter = avg_iter + dav_iter
             !
             ! ... save wave-functions to be used as input for the
             ! ... iterative diagonalization of the next scf iteration 
             ! ... and for rho calculation
             !
             IF ( nks > 1 .OR. .NOT. reduce_io ) &
                CALL davcio( evc, nwordwfc, iunwfc, ik, 1 )
             !  
             ntry = ntry + 1
             !
             ! ... exit condition
             !
             IF ( test_exit_cond() ) EXIT  david_loop
             !
          END DO david_loop
          !
          IF ( notconv /= 0 ) &
             WRITE( stdout, '(" warning : ",I3," eigenvectors not",&
                  &" converged after ",I3," attemps")') notconv, ntry
          !
          IF ( notconv > MAX( 5, nbnd / 4 ) ) THEN
             !
             CALL errore( 'c_bands', &
                        & 'too many bands are not converged', 1 )
             !
          END IF
          !
          ! ... save restart information
          !
          CALL save_in_cbands( iter, ik, dr2 )
          !
       END DO k_loop
       !
       ik_ = 0
       !
#if defined (__PARA)
       CALL poolreduce( 1, avg_iter )
#endif
       !
       avg_iter = avg_iter / nkstot
       !
       WRITE( stdout, &
              '( 5X,"ethr = ",1PE9.2,",  avg # of iterations =",0PF5.1 )' ) &
           ethr, avg_iter
       !
       ! ... deallocate work space
       !
       DEALLOCATE( becp, becp_ )
       !
       RETURN
       !
     END SUBROUTINE c_bands_gamma  
     !
     !     
     !-----------------------------------------------------------------------
     SUBROUTINE c_bands_k()
       !-----------------------------------------------------------------------
       !
       ! ... This routine is a driver for the diagonalization routines of the
       ! ... total Hamiltonian at each k-point.
       ! ... It reads the Hamiltonian and an initial guess of the wavefunctions
       ! ... from a file and computes initialization quantities for the
       ! ... diagonalization routines.
       ! ... There are three types of iterative diagonalization:
       ! ... a) Davidson algorithm (all-band)
       ! ... b) Conjugate Gradient (band-by-band)
       ! ... c) DIIS algorithm
       !
       IMPLICIT NONE
       !
       ! ... here the local variables
       !
       REAL(KIND=DP) :: cg_iter, diis_iter
         ! number of iteration in CG
         ! number of iteration in DIIS
       INTEGER, ALLOCATABLE :: btype(:)
         ! type of band: conduction (1) or valence (0)
       !
       !
       ! ... allocate specific array for DIIS
       !
       IF ( isolve == 2 ) &
          ALLOCATE( btype(  nbnd ) )    
       !
       IF ( isolve == 0 ) THEN
          !
          WRITE( stdout, '("     Davidson diagonalization (with overlap)")')
          !
       ELSE IF ( isolve == 1 ) THEN
          !
          WRITE( stdout, '("     Conjugate-gradient style diagonalization")')
          !
       ELSE IF ( isolve == 2 ) THEN
          !
          WRITE( stdout, '("     DIIS style diagonalization")')
          IF ( ethr > diis_ethr_cg ) &
             WRITE( stdout, '(6X,"use conjugate-gradient method ", &
                               & "until ethr <",1PE9.2)' ) diis_ethr_cg
       ELSE
          !
          CALL errore( 'c_bands', 'isolve not implemented', 1 )
          !
       END IF
       !
       avg_iter = 0.D0
       !
       ! ... v_of_0 is (Vloc)(G=0)
       !
       v_of_0 = dsum( nrxx, vltot, 1 ) / REAL( nr1 * nr2 * nr3 )
       !
#if defined (__PARA)
       CALL reduce( 1, v_of_0 )
#endif
       !
       if ( nks > 1 ) REWIND( iunigk )
       !
       ! ... For each k point diagonalizes the hamiltonian
       !
       k_loop: DO ik = 1, nks
          !
          IF ( lsda ) current_spin = isk(ik)
          !
          ! ... Reads the Hamiltonian and the list k+G <-> G of this k point
          !
          IF ( nks > 1 ) READ( iunigk ) npw, igk
          !
          ! ... do not recalculate k-points if restored from a previous run
          !
          IF ( ik <= ik_ ) THEN
             !
             CALL save_in_cbands( iter, ik, dr2 )
             !
             CYCLE k_loop
             !
          END IF
          !
          ! ... various initializations
          !
          IF ( nkb > 0 ) &
             CALL init_us_2( npw, igk, xk(1,ik), vkb )
          !
          ! ... read in wavefunctions from the previous iteration
          !
          IF ( nks > 1 .OR. .NOT. reduce_io ) &
             CALL davcio( evc, nwordwfc, iunwfc, ik, -1 )
          !   
          ! ... Needed for LDA+U
          !
          IF ( lda_plus_u ) CALL davcio( swfcatom, nwordatwfc, iunat, ik, -1 )
          !
          ! ... sets the kinetic energy
          !
          g2kin(1:npw) = ( ( xk(1,ik) + g(1,igk(1:npw)) )**2 + &
                           ( xk(2,ik) + g(2,igk(1:npw)) )**2 + &
                           ( xk(3,ik) + g(3,igk(1:npw)) )**2 ) * tpiba2          
          !
          !
          IF ( qcutz > 0.D0 ) THEN
             DO ig = 1, npw
                g2kin (ig) = g2kin(ig) + qcutz * &
                             ( 1.D0 + erf( ( g2kin(ig) - ecfixed ) / q2sigma ) )
             END DO
          END IF
          !
          IF ( ( isolve == 1 ) .OR. &
               ( isolve == 2 .AND. ethr > diis_ethr_cg ) ) THEN
             !
             ! ... Conjugate-Gradient diagonalization
             ! ... and first steps of RMM-DIIS diagonalization
             !
             ! ... h_diag is the precondition matrix
             !
             h_diag(1:npw) = MAX( 1.D0, g2kin(1:npw) )
             !
             ntry = 0
             !
             CG_loop : DO
                !
                IF ( iter /= 1 .OR. istep /= 1 .OR. ntry > 0 ) THEN
                   !
                   CALL cinitcgg( npwx, npw, nbnd, nbnd, evc, evc, et(1,ik) )
                   !
                   avg_iter = avg_iter + 1.D0
                   !
                END IF
                !
                CALL ccgdiagg( npwx, npw, nbnd, evc, et(1,ik), h_diag, ethr, &
                               max_cg_iter, .not.lscf, notconv, cg_iter )
                !
                avg_iter = avg_iter + cg_iter
                !
                ! ... save wave-functions to be used as input for the
                ! ... iterative diagonalization of the next scf iteration 
                ! ... and for rho calculation
                !
                IF ( nks > 1 .OR. .NOT. reduce_io ) &
                   CALL davcio( evc, nwordwfc, iunwfc, ik, 1 )
                !
                ntry = ntry + 1                
                !
                ! ... exit condition
                !
                IF ( test_exit_cond() ) EXIT  CG_loop
                !
             END DO CG_loop
             !
          ELSE IF ( isolve == 2 ) THEN
             !
             ! ... when ethr <= diis_ethr_cg  start the RMM-DIIS method
             !
             h_diag(1:npw) = g2kin(1:npw) + v_of_0
             !
             CALL usnldiag( h_diag, s_diag )
             !
             ntry = 0
             diis_iter = 0.D0
             !
             btype(:) = 0
             !
             IF ( iter > 1 ) &
                WHERE( wg(:,ik) < 1.0D-4 ) btype(:) = 1
             !
             RMMDIIS_loop: DO
                !
                CALL cdiisg( npw, npwx, nbnd, diis_ndim, evc, et(1,ik), ethr, &
                             btype, notconv, diis_iter, iter )
                !  
                avg_iter = avg_iter + diis_iter
                !
                ! ... save wave-functions to be used as input for the
                ! ... iterative diagonalization of the next scf iteration 
                ! ... and for rho calculation
                !
                IF ( nks > 1 .OR. .NOT. reduce_io ) &
                   CALL davcio( evc, nwordwfc, iunwfc, ik, 1 )
                !
                ntry = ntry + 1                
                !
                ! ... exit condition
                !
                IF ( test_exit_cond() ) EXIT  RMMDIIS_loop
                !
             END DO RMMDIIS_loop
             !
          ELSE
             !
             ! ... Davidson diagonalization
             !
             ! ... h_diag are the diagonal matrix elements of the
             ! ... hamiltonian used in g_psi to evaluate the correction 
             ! ... to the trial eigenvectors
             !
             h_diag(1:npw) = g2kin(1:npw) + v_of_0
             !
             CALL usnldiag( h_diag, s_diag )
             !
             ntry = 0
             !
             david_loop: DO
                !
                CALL cegterg( npw, npwx, nbnd, nbndx, evc, ethr, okvan, &
                              et(1,ik), notconv, dav_iter )
                !
                avg_iter = avg_iter + dav_iter
                !
                ! ... save wave-functions to be used as input for the
                ! ... iterative diagonalization of the next scf iteration 
                ! ... and for rho calculation
                !
                IF ( nks > 1 .OR. .NOT. reduce_io ) &
                   CALL davcio( evc, nwordwfc, iunwfc, ik, 1 )
                !
                ntry = ntry + 1                
                !
                ! ... exit condition
                !
                IF ( test_exit_cond() ) EXIT david_loop                
                !
             END DO david_loop
             !
          END IF
          !
          IF ( notconv /= 0 ) &
             WRITE( stdout, '(" warning : ",i3," eigenvectors not",&
                  &" converged after ",i3," attemps")') notconv, ntry
          !
          IF ( notconv > MAX( 5, nbnd / 4 ) ) THEN
             !
             CALL errore( 'c_bands', &
                        & 'too many bands are not converged', 1 )
             !
          END IF
          !
          ! ... save restart information
          !
          CALL save_in_cbands( iter, ik, dr2 )
          !
       END DO k_loop
       !
       ik_ = 0
       !
#if defined (__PARA)
       CALL poolreduce( 1, avg_iter )
#endif
       !
       avg_iter = avg_iter / nkstot
       !
       WRITE( stdout, &
              '( 5X,"ethr = ",1PE9.2,",  avg # of iterations =",0PF5.1 )' ) &
           ethr, avg_iter
       !
       IF ( isolve == 2 ) &
          DEALLOCATE( btype )
       !
       RETURN
       !
     END SUBROUTINE c_bands_k
     !
     !
     !-----------------------------------------------------------------------
     FUNCTION test_exit_cond()
       !-----------------------------------------------------------------------
       !
       ! ... this logical function is .TRUE. when iterative diagonalization
       ! ... is converged
       !
       IMPLICIT NONE
       !
       LOGICAL :: test_exit_cond
       !
       !
       test_exit_cond = .NOT. ( ( ntry <= 5 ) .AND. &
                                ( ( .NOT. lscf .AND. ( notconv > 0 ) ) .OR. &
                                  (       lscf .AND. ( notconv > 5 ) ) ) )
       !                          
     END FUNCTION test_exit_cond
     !     
END SUBROUTINE c_bands
