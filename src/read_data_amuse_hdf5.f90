!-----------------------------------------------------------------
!
!  This file is (or was) part of SPLASH, a visualisation tool
!  for Smoothed Particle Hydrodynamics written by Daniel Price:
!
!  http://users.monash.edu.au/~dprice/splash
!
!  SPLASH comes with ABSOLUTELY NO WARRANTY.
!  This is free software; and you are welcome to redistribute
!  it under the terms of the GNU General Public License
!  (see LICENSE file for details) and the provision that
!  this notice remains intact. If you modify this file, please
!  note section 2a) of the GPLv2 states that:
!
!  a) You must cause the modified files to carry prominent notices
!     stating that you changed the files and the date of any change.
!
!  Copyright (C) 2005-2014 Daniel Price. All rights reserved.
!  Contact: daniel.price@monash.edu
!
!-----------------------------------------------------------------

!-------------------------------------------------------------------------
! this subroutine reads from the data file(s)
! change this to change the format of data input
!
! THIS VERSION IS FOR HDF5 OUTPUT FROM THE AMUSE FRAMEWORK
!
! the data is stored in the global array dat
!
! >> this subroutine must return values for the following: <<
!
! ncolumns    : number of data columns
! ndim, ndimV : number of spatial, velocity dimensions
! nstepsread  : number of steps read from this file
!
! dat(maxpart,maxplot,maxstep) : main data array
!
! npartoftype(maxstep): number of particles of each type in each timestep
!
! time(maxstep)       : time at each step
! gamma(maxstep)      : gamma at each step
!                      (used in calc_quantities for calculating the pressure)
!
! most of these values are stored in global arrays
! in the module 'particle_data'
!
! Columns with the 'required' flag set to false are not read
!-------------------------------------------------------------------------
!
!  The module below contains interface routines to c functions
!  that perform the actual calls to the HDF5 libs
!
!-------------------------------------------------------------------------
module amusehdf5read
 use params, only:maxplot,doub_prec
 use labels, only:lenlabel
 use, intrinsic :: iso_c_binding, only:c_int,c_double,c_char
 implicit none
 real :: hsoft
 character(len=lenlabel), dimension(maxplot) :: blocklabel
 logical :: havewarned = .false.
 integer, parameter :: maxtypes = 6

 interface
  subroutine read_amuse_hdf5_header(filename,npart,ncol,ndim,ndimV,time,ierr) bind(c)
   import
   character(kind=c_char), dimension(*), intent(in) :: filename
   integer(kind=c_int), intent(out) :: npart,ncol,ndim,ndimV,ierr
   real(kind=c_double), intent(out) :: time
  end subroutine read_amuse_hdf5_header

  subroutine read_amuse_hdf5_data(filename,maxtypes,npartoftypei,&
                                    ncol,isrequired,ierr) bind(c)
   import
   implicit none
   character(kind=c_char), dimension(*), intent(in)  :: filename
   integer(kind=c_int), intent(in), value :: maxtypes
   integer(kind=c_int), dimension(6), intent(in) :: npartoftypei
   integer(kind=c_int), intent(in), value  :: ncol
   integer(kind=c_int), intent(out) :: ierr
   integer(kind=c_int), dimension(ncol), intent(in)  :: isrequired
  end subroutine read_amuse_hdf5_data
 end interface

end module amusehdf5read

!-------------------------------------------------------------------------
!
!  The routine that reads the data into splash's internal arrays
!
!-------------------------------------------------------------------------

module readdata_amuse_hdf5
 implicit none

 public :: read_data_amuse_hdf5, set_labels_amuse_hdf5

 private
contains

subroutine read_data_amuse_hdf5(rootname,istepstart,ipos,nstepsread)
 use particle_data,  only:dat,npartoftype,masstype,time,gamma,maxpart,maxcol,maxstep
 use params,         only:doub_prec,maxplot
 use settings_data,  only:ndim,ndimV,ncolumns,ncalc,required,ipartialread, &
                           ntypes,iverbose,debugmode
 use settings_page,  only:legendtext
 use mem_allocation, only:alloc
 use labels,         only:ih,irho,ipmass
 use system_utils,   only:renvironment,lenvironment,ienvironment,envlist
 use asciiutils,     only:cstring
 use amusehdf5read,  only:havewarned,read_amuse_hdf5_header,read_amuse_hdf5_data
 integer, intent(in)                :: istepstart,ipos
 integer, intent(out)               :: nstepsread
 character(len=*), intent(in)       :: rootname
 character(len=len(rootname)+10)    :: datfile
 integer               :: i,j,ierr
 integer               :: nhfac
 integer               :: ncolstep,npart_max,nstep_max,ntoti
 logical               :: iexist,reallocate,debug,goterrors
 real(doub_prec)       :: timetemp
 real :: hfact,hfactmean,pmassi
 real, parameter :: pi = 3.1415926536
 integer, dimension(maxplot) :: isrequired

 nstepsread = 0
 goterrors  = .false.
 debug = debugmode

 if (len_trim(rootname) > 0) then
    datfile = trim(rootname)
 else
    print*,' **** no data read **** '
    return
 endif
!
!--check if first data file exists
!
 print "(1x,a)",'reading AMUSE HDF5 format'
 inquire(file=datfile,exist=iexist)
 if (.not.iexist) then
    !
    !--append .hdf5 on the endif not already present
    !
    datfile=trim(rootname)//'.hdf5'
    inquire(file=datfile,exist=iexist)
    if (.not.iexist) then
       print "(a)",' *** error: '//trim(rootname)//': file not found ***'
       return
    endif
 endif
!
!--set parameters which do not vary between timesteps
!
 ndim  = 3
 ndimV = 3
!
!--read data from snapshots
!
 i = istepstart
 write(*,"(23('-'),1x,a,1x,23('-'))") trim(datfile)
 !
 !--open file and read header information
 !
 if (debug) print*,'DEBUG: reading header...'
 call read_amuse_hdf5_header(cstring(datfile),ntoti,ncolstep,ndim,ndimV,timetemp,ierr)
 if (ierr /= 0) then
    print "(a)", '*** ERROR READING HEADER ***'
    return
 endif
 ncolumns = ncolstep

 if (iverbose >= 1) print "(2(a,1x,i10))",' npart: ',ntoti,' ncolumns: ',ncolstep
 !
 !--now read data
 !
 reallocate = .false.
 npart_max = maxpart
 nstep_max = max(maxstep,1)

 if (ntoti > maxpart) then
    reallocate = .true.
    if (maxpart > 0) then
       ! if we are reallocating, try not to do it again
       npart_max = int(1.1*ntoti)
    else
       ! if first time, save on memory
       npart_max = int(ntoti)
    endif
 endif
 if (i >= maxstep .and. i /= 1) then
    nstep_max = i + max(10,INT(0.1*nstep_max))
    reallocate = .true.
 endif
 !
 !--reallocate memory for main data array
 !
 if (reallocate .or. .not.(allocated(dat))) then
    call alloc(npart_max,nstep_max,max(ncolumns+ncalc,maxcol))
 endif

 !
 !--copy header data into allocated arrays
 !
 npartoftype(1,i) = ntoti
 time(i) = real(timetemp)
 masstype(:,i) = 0. ! all masses read from file
 !
 !--read particle data
 !
 got_particles: if (ntoti > 0) then

    isrequired(:) = 0
    where (required(1:ncolumns)) isrequired(1:ncolumns) = 1

    call read_amuse_hdf5_data(cstring(datfile),ntypes,npartoftype(:,i),ncolumns,isrequired,ierr)

    nstepsread = 1
 endif got_particles
!
!--now memory has been allocated, set arrays which are constant for all time
!
 gamma = 5./3.
!
!--set flag to indicate that only part of this file has been read
!
 if (.not.all(required(1:ncolstep))) ipartialread = .true.
!
!--call set labels to identify location of smoothing length
!
 call set_labels_amuse_hdf5
!
!--for read from multiple files, work out the next file in the sequence
!
 !
 !--for some reason the smoothing length output by GADGET is
 !  twice the usual SPH smoothing length
 !  (do this after we have read data from all of the files)
 !
 if (required(ih) .and. size(dat(1,:,:)) >= ih .and. npartoftype(1,i) > 0 .and. ih > 0) then
    print "(a)",' converting GADGET smoothing length on gas particles to usual SPH definition (x 0.5)'
    dat(1:npartoftype(1,i),ih,i) = 0.5*dat(1:npartoftype(1,i),ih,i)
 endif

!
!--give a friendly warning about using too few or too many neighbours
!  (only works with equal mass particles because otherwise we need the number density estimate)
!
 if (ih > 0 .and. required(ih) .and. ipmass > 0 .and. required(ipmass) &
      .and. abs(masstype(1,i)) < tiny(0.) .and. ndim==3 .and. .not.havewarned) then
    nhfac = 100
    if (npartoftype(1,i) > nhfac) then
       hfactmean = 0.
       do j=1,nhfac
          pmassi = dat(j,ipmass,i)
          if (pmassi > 0.) then
             pmassi = 1./pmassi
          else
             pmassi = 0.
          endif
          hfact = dat(j,ih,i)*(dat(j,irho,i)*pmassi)**(1./ndim)
          hfactmean = hfactmean + hfact
       enddo
       hfact = hfactmean/real(nhfac)
       havewarned = .true.
       print "(/,1x,a,f5.1,a,/,1x,a,f4.2,a,i1,a,/)", &
             'Simulations employ ',4./3.*pi*(2.*hfact)**3,' neighbours,', &
             'corresponding to h = ',hfact,'*(m/rho)^(1/',ndim,') in 3D'
    endif
 endif
!
!--cover the special case where no particles have been read
!
 if (ntoti <= 0) then
    npartoftype(1,i) = 1
    dat(:,:,i) = 0.
 endif

 if (nstepsread > 0) then
    print "(a,i10,a)",' >> read ',sum(npartoftype(:,istepstart+nstepsread-1)),' particles'
 endif
 return

end subroutine read_data_amuse_hdf5

subroutine read_amuse_hdf5_data_fromc(icol,npartoftypei,temparr,itype) bind(c)
 use, intrinsic :: iso_c_binding, only:c_int,c_double
 use particle_data,  only:dat,iamtype
 use settings_data,  only:debugmode
 use labels,         only:label
 integer(kind=c_int), intent(in) :: icol,npartoftypei,itype
 real(kind=c_double), intent(in) :: temparr(npartoftypei)
 integer(kind=c_int) :: i,icolput
 integer :: nmax

 icolput = icol
 if (debugmode) print "(a,i2,a,i2,a,i8)",'DEBUG: reading column ',icol,' type ',itype,' -> '//trim(label(icolput))

 ! check column is within array limits
 if (icolput > size(dat(1,:,1)) .or. icolput==0) then
    print "(a,i2,a)",' ERROR: column = ',icolput,' out of range in receive_data_fromc'
    return
 endif

 ! ensure no array overflows
 nmax = min(npartoftypei,size(dat(:,1,1)))

 ! copy data into main splash array
 dat(1:nmax,icolput,1) = real(temparr(1:nmax))

 ! set particle type
 if (size(iamtype(:,1)) > 1) then
    do i=1,nmax
       iamtype(i,1) = int(itype + 1,kind=kind(iamtype))
    enddo
 endif

end subroutine read_amuse_hdf5_data_fromc

!!------------------------------------------------------------
!! set labels for each column of data
!!------------------------------------------------------------

subroutine set_labels_amuse_hdf5
 use labels,        only:label,iamvec,labelvec,labeltype,ix,ivx,ipmass, &
                          ih,irho,iutherm,iax,make_vector_label
 use params
 use settings_data,  only:ndim,ndimV,UseTypeInRenderings
 use geometry,       only:labelcoord
 use system_utils,   only:envlist,ienvironment
 use amusehdf5read,  only:blocklabel
 use asciiutils,     only:lcase
 integer :: icol

 if (ndim <= 0 .or. ndim > 3) then
    print*,'*** ERROR: ndim = ',ndim,' in set_labels_amuse_hdf5 ***'
    return
 endif
 if (ndimV <= 0 .or. ndimV > 3) then
    print*,'*** ERROR: ndimV = ',ndimV,' in set_labels_amuse_hdf5 ***'
    return
 endif

 ix = 0
 iutherm = 0
 do icol=1,size(blocklabel)
    select case(trim(lcase(blocklabel(icol))))
    case('x')
       ix(1) = icol
    case('y')
       ix(2) = icol
    case('z')
       ix(3) = icol
    case('vx')
       ivx = icol
    case('ax')
       iax = icol
    case('h_smooth')
       ih = icol
    case('mass')
       ipmass = icol
    case('density')
       irho = icol
    end select
    label(icol) = trim(blocklabel(icol))
 enddo

 ! set labels of the quantities read in
 if (ix(1) > 0)   label(ix(1:ndim)) = labelcoord(1:ndim,1)

 ! set labels for vector quantities
 call make_vector_label('v',ivx,ndimV,iamvec,labelvec,label,labelcoord(:,1))
 call make_vector_label('a',iax,ndimV,iamvec,labelvec,label,labelcoord(:,1))

 ! set labels for each particle type
 labeltype(1) = 'gas'
 UseTypeInRenderings(:) = .false.
 UseTypeInRenderings(1) = .true.

!-----------------------------------------------------------
 return
end subroutine set_labels_amuse_hdf5

subroutine set_blocklabel(icol,name) bind(c)
 use, intrinsic :: iso_c_binding, only:c_int, c_char
 use amusehdf5read, only:blocklabel
 use asciiutils,    only:fstring
 integer(kind=c_int),    intent(in) :: icol
 character(kind=c_char), intent(in) :: name(256)

 blocklabel(icol) = trim(fstring(name))
 !print*,icol,' name = ',trim(blocklabel(icol))

end subroutine set_blocklabel
end module readdata_amuse_hdf5
